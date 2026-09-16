#!/bin/bash
set -euo pipefail

# ============================================================================
# restic CLIENT backup -- ONE script for every client (servers AND laptop).
# Pushes to the APPEND-ONLY rest-server reachable ONLY over WireGuard, at
# rest:http://10.0.0.2:8000/<user>/.
#
# WireGuard is the transport security: the hop is already encrypted and
# peer-authenticated, so there is NO TLS, NO proxy, and NO "am I home / trusted
# Wi-Fi" gating -- if the tunnel is up and 10.0.0.2 answers, we back up from
# anywhere; if it isn't, 10.0.0.2 isn't routable (captive portals included) and
# we skip. Run WG SPLIT-TUNNEL (AllowedIPs = 10.0.0.0/24) so the ntfy / DMS
# paths stay on the normal internet and can still alert when the tunnel is down.
#
# Still enforced server-side, independent of WG:
#   - append-only  : a compromised (but valid) peer cannot delete its history.
#   - private-repos: per-client htpasswd isolates peers sharing the WG subnet.
# Retention + prune + check run on the maintenance host, not here.
# `restic unlock` is kept (rest-server append-only permits lock removal) to
# self-heal stale locks from interrupted laptop runs; stale-only, so it can't
# disturb a live maintenance prune.
#
# ---------------------------------------------------------------------------
# SELF-SCHEDULING. Cron invokes this HOURLY; the script decides whether this
# particular hour is the moment to run. ONE rule does it, and it has no knobs:
#
#   back up when nothing has succeeded yet TODAY (local calendar day).
#
# The first invocation after local midnight is therefore the one that backs up
# -- the night run -- and every later hour of the same day is a RETRY that only
# fires while that night run has not succeeded: backend down, tunnel down,
# machine asleep. A daytime backup is always a fallback, never a schedule, and
# the next midnight puts the host back on the night slot regardless of which
# hour today's success finally landed on.
#
# It compares DAYS on purpose, not an elapsed-hours interval. Any "not sooner
# than N hours" rule measures from the last success, so one run that slips into
# the afternoon drags the next one to the afternoon as well and the backup
# walks around the clock, away from the night, with nothing to pull it back.
# Comparing calendar days has no such feedback: the deadline is midnight, which
# does not move because a run was late. It is also why DST costs nothing here
# -- no hour arithmetic is done on the schedule at all.
#
# Plain cron does NOT replay jobs missed while a machine was off or asleep (no
# anacron, no systemd Persistent=). The hourly retry IS the catch-up: a laptop
# that is never awake at night backs up in its first awake hour, once a day.
# That makes $CONFIG_DIR/.last-success load-bearing -- it is the only record of
# when a backup last worked, and the entire schedule is derived from it.
#
# MAX_BACKUP_AGE_HOURS=36 is the hard fail. Every path that declines to back up
# (not due, metered, tunnel down) exits through stale_exit(), so a host that
# quietly stops backing up alerts LOCALLY instead of relying on the external
# dead-man's switch. This is what makes a skip safe: a skip cannot hide.
# Losing the lock is the one skip judged on a different number -- how long the
# HOLDER has held it, because .last-success describes a run that has already
# finished, not the one still going (see the lock section). Same threshold.
# A transient failure is logged and retried the next hour;
# only the first failure after a success, and the crossing of MAX_BACKUP_AGE,
# page you (see notify_failure) -- 24 invocations a day must not mean 24 pushes.
# A run the machine SLEPT through is logged and nothing more, on the same
# threshold: a closed lid is not a fault report, and the next hour picks it up.
#
# Run by hand with --force (bypass every gate) or --status (print the decision
# and report through the exit code, alerting nobody).
# ---------------------------------------------------------------------------
#
# Requires restic >= 0.16 (--retry-lock). Keep client restic <= maintenance host.
# ============================================================================

# Absolute and CLOSED -- the inherited PATH is deliberately NOT appended. This
# script runs as root and resolves `ip`, `nmcli`, `restic`, `flock` and the dump
# tools by name; keeping a caller-supplied tail in PATH would let a poisoned
# environment (a manual run, a wrapper, a non-cron scheduler) satisfy any of
# them from a directory it controls. sbin is included because `ip` lives in
# /usr/sbin on distributions that are not usr-merged.
#
# If restic (or anything else this needs) lives somewhere else -- /opt, /snap/bin
# for a snap install, a Go workspace -- extend it from the config, which is
# sourced below and is verified to be root-owned before it is:
#     export PATH="/snap/bin:$PATH"
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# ---- Arguments ----
# Read from RESTIC_BACKUP_FORCE, never from a bare FORCE. This runs from cron
# on every host, and FORCE is a common enough name that a wrapper, a CI job or
# an exporting parent shell could switch off the once-a-day gate and the
# metered gate on every hourly run without anyone meaning to -- and the
# only trace would be a log line reading "forced (--force)" for a run where no
# flag was passed.
FORCE="${RESTIC_BACKUP_FORCE:-0}"
[[ "$FORCE" =~ ^[01]$ ]] || FORCE=0
FORCE_SOURCE="RESTIC_BACKUP_FORCE"
STATUS_ONLY=0
CHECK_UPDATE_ONLY=0
usage() {
  cat <<'USAGE'
Usage: restic-backup.sh [--force] [--status] [--check-update]

  --force         back up now even though today's backup already succeeded,
                  and ignoring the metered gate (reachability still applies --
                  there would be nowhere to push to)
  --status        print the scheduling decision and exit; alerts nobody.
                  Exit 0 healthy, 3 past MAX_BACKUP_AGE_HOURS, 1 cannot tell
  --check-update  compare this file against the published version and report.
                  NEVER downloads or installs anything -- deploy with deploy.sh
USAGE
}
while (( $# )); do
  case "$1" in
    -f|--force)        FORCE=1; FORCE_SOURCE="--force" ;;
    -s|--status)       STATUS_ONLY=1 ;;
    --check-update)    CHECK_UPDATE_ONLY=1 ;;
    -h|--help)         usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

# --status and --check-update are diagnostic: they must SPEND nothing anyone
# else is waiting on. (Not "change nothing": --status does seed .first-seen, and
# has to -- see the comment there. The distinction is starting a clock, which is
# free, against consuming a one-shot, which is not.)
# Every config guard below reaches preflight_fail, which is an
# ALERTING path -- it pings the dead-man's switch, pushes an urgent ntfy, and
# records the push in $NOTIFY_STATE_FILE. Running --status against a host with a
# broken config would therefore page whoever is on call, and -- worse -- consume
# the one-shot: the throttle is "first failure after a success always pushes",
# so the next real hourly run would find the alert already spent and log
# "notification suppressed" instead of paging. deploy.sh --check fans exactly
# this across the fleet on every CI run. So: in these modes the alert primitives
# are inert and no notification state is written. The diagnosis still prints,
# and the exit code is still non-zero.
REPORT_ONLY=0
(( STATUS_ONLY || CHECK_UPDATE_ONLY )) && REPORT_ONLY=1

SELF_PATH="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"

# ---- Small helpers (needed while validating the config) ----
log() { printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*"; }

fmt_age() {                            # seconds -> "12h34m" ("never" for < 0)
  local s="${1:-0}"
  (( s < 0 )) && { printf 'never'; return; }
  printf '%dh%02dm' $(( s / 3600 )) $(( (s % 3600) / 60 ))
}

read_epoch() {                         # file -> epoch on stdout, 0 if unusable
  local f="$1" v=0
  if [[ -s "$f" ]]; then
    # `read` returns 1 at EOF-without-newline, but only AFTER assigning v, so a
    # value written with `echo -n` (repairing state by hand, say) would be thrown
    # away here and read as "no successful backup ever". The regex below is what
    # actually validates it.
    read -r v < "$f" || true
    [[ "$v" =~ ^[0-9]+$ ]] || v=0
  fi
  printf '%s' "$v"
}

# The kernel's tally of completed suspend cycles since boot, or "" where the
# kernel does not publish one. notify_failure compares it across a run to tell a
# backup the machine slept through from one the backend actually rejected.
#
# Counts suspend-to-RAM and s2idle -- what both a closed lid and `systemctl
# suspend` do. Hibernation takes a different kernel path and is NOT counted, so
# a hibernated run still pages: sysfs publishes no counter for it, and it is
# rare enough on these hosts to leave loud rather than guess at.
#
# Never fails and never returns non-zero: it is read from inside the failure
# path, where a non-zero return under the ERR trap would page about the
# notification code instead of about the backup.
suspend_count() {                      # -> count on stdout, "" if unavailable
  local n=""
  # Braced so 2>/dev/null covers the `<` as well. Redirections are applied left
  # to right, so a trailing one is not yet in place to swallow the shell's own
  # "No such file or directory" -- and a kernel that publishes no counter would
  # print that into the log on every failure (same ordering as write_state).
  #
  # `|| true` rather than `|| n=""`, for read_epoch's reason: read returns 1 at
  # EOF-without-newline, but only AFTER assigning, so clearing n here would throw
  # away a counter written without one. The regex below is the real validator.
  { read -r n < /sys/power/suspend_stats/success; } 2>/dev/null || true
  [[ "$n" =~ ^[0-9]+$ ]] && printf '%s' "$n"
  return 0
}

# read_epoch's counterpart, and the ONLY way this script writes a state file.
# Two properties, both load-bearing:
#   atomic      -- writes $f.tmp and renames it into place, so the file is
#                  always either the old value or the new one. A plain `> file`
#                  truncates before it writes, and losing power inside that
#                  window leaves a 0-byte .last-success: read_epoch reports 0,
#                  the scheduler reads "no successful backup ever",
#                  ALERT_AGE_SEC falls back to .first-seen, and on a host with
#                  months of history the next ordinary failure pages "No
#                  successful backup for 8760h00m". (Not fsynced: a crash can
#                  still lose the write, but it cannot leave a truncated file.)
#   never fatal -- under `set -e` a failed write (read-only /, full disk) would
#                  abort the script, and in version_check that runs AFTER the
#                  backup succeeded: the ERR trap would page "Backup FAILED"
#                  about a backup that actually worked.
write_state() {                        # write_state FILE LINE...
  local f="$1"; shift
  # 2>/dev/null first: redirections are applied left to right, so a later one
  # would not yet be in place to swallow the shell's own "cannot create" error.
  if { printf '%s\n' "$*" > "$f.tmp"; } 2>/dev/null && mv -f "$f.tmp" "$f" 2>/dev/null; then
    return 0
  fi
  rm -f "$f.tmp" 2>/dev/null || true
  log "WARN: could not write $f (state not recorded)"
  return 0
}

# ---- Trusted paths -------------------------------------------------------
# `source config` and the pre-backup hook both EXECUTE their file as root, once
# an hour, unattended. Existence is therefore not a sufficient check: anything
# that can write the file -- or write the directory holding it, which amounts to
# the same thing -- owns root on this host by the next tick. The README installs
# these 700/600, but a restore with wrong ownership, a hand-created directory or
# a CONFIG_DIR moved somewhere laxer all defeat that, silently. Verify instead.
#
# "Trusted" = owned by root or by us, and not writable by group or other, for
# the file and for EVERY directory on the way to it.
path_is_trusted() {                    # path -> 0 if nobody else can write it
  local p="$1" owner mode
  owner=$(stat -Lc %u "$p" 2>/dev/null) || return 1
  mode=$(stat -Lc %a "$p" 2>/dev/null)  || return 1
  (( owner == 0 || owner == EUID )) || return 1
  # A sticky world-writable DIRECTORY (/tmp) is fine: only the owner can rename
  # or unlink an entry, so an existing file in it cannot be swapped out. The
  # same bits on a file, or on a non-sticky directory, are not.
  if [[ -d "$p" ]] && (( 8#$mode & 01000 )); then return 0; fi
  (( 8#$mode & 0022 )) && return 1
  return 0
}

require_trusted() {                    # require_trusted PATH DESCRIPTION
  local p="$1" desc="$2" d
  if ! path_is_trusted "$p"; then
    preflight_fail "$desc ($p) must be owned by root or UID $EUID and not group/world-writable.
It is executed as UID $EUID, so anyone who can write it owns this host."
  fi
  d="$(dirname "$(readlink -f "$p")")"
  while :; do
    if ! path_is_trusted "$d"; then
      preflight_fail "$desc ($p) sits under a directory anyone can write ($d)"
    fi
    [[ "$d" == / ]] && break
    d="$(dirname "$d")"
  done
}

# Every integer knob goes through here, so the default lives in exactly ONE
# place: it seeds the value when the config is silent AND it is what a
# malformed value falls back to. Falling back to the DEFAULT rather than to 0
# is the whole point -- 0 is meaningful for most of these knobs ("never
# hard-fail on age", "never re-page"), so coercing a typo to 0 would quietly
# switch off the alarm the config was trying to set. An explicit 0 is kept.
int_cfg() {                            # int_cfg NAME DEFAULT
  local _n="$1" _d="$2" _raw
  declare -n _ref="$_n"
  _raw="${_ref:-$_d}"
  if [[ ! "$_raw" =~ ^[0-9]+$ ]]; then
    log "WARN: $_n='$_raw' is not a whole number; using the default $_d."
    log "WARN: Fix $CONFIG_DIR/config -- a typo must not silently change this knob."
    _raw="$_d"
  fi
  _ref="$_raw"
}

# ---- Load per-host config ----
CONFIG_DIR="${RESTIC_CONFIG_DIR:-$HOME/.config/restic}"

# ============================================================================
#  NOTIFICATION BOOTSTRAP  --  built BEFORE the config is loaded, on purpose.
#
#  Everything that can go wrong while loading the config is otherwise completely
#  silent: the ntfy and DMS settings live IN that config, so a file that will
#  not parse -- a half-finished hand-edit, an interrupted deploy -- dies with a
#  bash error into `logger`, and MAILTO="" in the cron file ends it there. No
#  push, no /fail ping, and not even the local staleness alarm, which is further
#  down still. The host stops backing up and nothing anywhere says a word;
#  only the external dead-man's switch notices, a grace period later.
#
#  So the senders, the throttle and its state files are set up here, seeded from
#  a pre-parse that reads the config as TEXT and never executes it, and an ERR
#  trap is armed before the config is touched at all. Everything below re-reads
#  the same values from the real config once sourcing has succeeded.
# ============================================================================

# State. Cheap, local, and the only thing that survives a reboot: .last-success
# is what every scheduling and staleness decision is measured against.
LAST_SUCCESS_FILE="$CONFIG_DIR/.last-success"
FIRST_SEEN_FILE="$CONFIG_DIR/.first-seen"
NOTIFY_STATE_FILE="$CONFIG_DIR/.notify-state"
VERSION_STATE_FILE="$CONFIG_DIR/.version-state"
LOCK_FILE="$CONFIG_DIR/.lock"
WG_BOUNCE_FILE="$CONFIG_DIR/.wg-bounce"
MOUNT_GAP_FILE="$CONFIG_DIR/.mount-gap-state"
ALERT_AGE_SEC=-1                       # set for real below; safe default for the ERR trap
NOTIFY_REPEAT_SEC=43200                # 12h, the default; recomputed from the config below

# Read BEFORE anything that can fail, so the window it opens spans the WHOLE
# run: a suspend during the database dumps breaks the upload that follows just
# as thoroughly as one during the upload itself, and the ERR trap can fire from
# anywhere in between. Empty on a kernel without the counter, which
# notify_failure reads as "did not sleep" and pages about as usual.
SUSPENDS_AT_START="$(suspend_count)"

# Pull ONE literal setting out of the config without running it. Deliberately
# narrow: only a single-quoted or double-quoted literal on its own line, with no
# expansion or substitution in it, is accepted -- anything else needs a shell,
# which is precisely what we cannot have yet. A miss just leaves the value empty
# and costs us the notification we were trying to salvage, never more than that.
cfg_peek() {                           # cfg_peek NAME -> literal value on stdout
  [[ -r "$CONFIG_DIR/config" ]] || return 0
  sed -n -E "s/^[[:space:]]*(export[[:space:]]+)?$1=\"([^\"\$\`]*)\".*/\2/p;
             s/^[[:space:]]*(export[[:space:]]+)?$1='([^'\$\`]*)'.*/\2/p" \
      "$CONFIG_DIR/config" 2>/dev/null | tail -n1
}

NTFY_URL="${NTFY_URL:-$(cfg_peek NTFY_URL)}"
NTFY_TOKEN="${NTFY_TOKEN:-$(cfg_peek NTFY_TOKEN)}"
NTFY_TOPIC_HIGH="${NTFY_TOPIC_HIGH:-$(cfg_peek NTFY_TOPIC_HIGH)}"
NTFY_TOPIC_HIGH="${NTFY_TOPIC_HIGH:-backups-high}"
NTFY_TOPIC_LOW="${NTFY_TOPIC_LOW:-}"
PING_URL="${RESTIC_PING_URL:-$(cfg_peek RESTIC_PING_URL)}"

# Both senders talk to curl through `-K -` -- a config file on STDIN -- rather
# than through argv. The ntfy token and the dead-man's-switch URL are secrets
# (the config says so), and a command line is world-readable for as long as the
# process lives: `ps auxww` during a 15-second retrying curl hands any local user
# the token, which is publish rights on the alert topic, and the ping URL, which
# is the ability to keep the dead-man's switch quiet while a host stops backing
# up. The body goes the same way -- it carries the tail of restic's stderr.
#
# Values are quoted per curl's config syntax: backslash, double quote and the
# line endings need escaping, and nothing else does.
curl_cfg_quote() {
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"; s="${s//$'\r'/\\r}"; s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

ping_dms() {
  (( REPORT_ONLY )) && return 0
  [[ -n "$PING_URL" ]] || return 0
  {
    printf 'url = "%s"\n' "$(curl_cfg_quote "$1")"
    printf 'silent\nshow-error\nfail\nmax-time = 10\nretry = 3\n'
  } | curl -K - >/dev/null 2>&1 || true
}

ntfy() {
  local topic="$1" priority="$2" tags="$3" title="$4" body="$5"
  (( REPORT_ONLY )) && return 0
  [[ -n "$NTFY_URL" ]] || return 0
  {
    printf 'url = "%s"\n'              "$(curl_cfg_quote "$NTFY_URL/$topic")"
    printf 'header = "Title: %s"\n'    "$(curl_cfg_quote "$title")"
    printf 'header = "Priority: %s"\n' "$(curl_cfg_quote "$priority")"
    printf 'header = "Tags: %s"\n'     "$(curl_cfg_quote "$tags")"
    if [[ -n "$NTFY_TOKEN" ]]; then
      printf 'header = "Authorization: Bearer %s"\n' "$(curl_cfg_quote "$NTFY_TOKEN")"
    fi
    printf 'data-binary = "%s"\n'      "$(curl_cfg_quote "$body")"
    printf 'silent\nshow-error\nfail\nmax-time = 15\nretry = 3\n'
  } | curl -K - >/dev/null 2>&1 || log "WARN: ntfy send failed"
}

# Hourly invocation means a stuck host would push 24 urgent notifications a day.
# Policy, keyed off $NOTIFY_STATE_FILE ("<first> <last> <hard>", removed on every
# success):
#   - first failure after a success  -> always push (breakage is actionable NOW)
#   - later failures, still under MAX_BACKUP_AGE -> log + DMS only
#   - crossing MAX_BACKUP_AGE        -> push once more (escalation)
#   - beyond that                    -> push at most every NOTIFY_REPEAT_HOURS,
#                                       or never again if that is 0
# notify_failure applies one rule ahead of all of these: a failure on a run the
# machine suspended during is logged only, and reaches neither this throttle nor
# its state file, while the host is still inside MAX_BACKUP_AGE.
# Returns 0 if this event should be pushed. Always records the attempt.
notify_should_push() {
  (( REPORT_ONLY )) && return 1     # never push, and never record an attempt
  local hard="$1" now first last hardflag
  now=$(date +%s)
  if [[ ! -s "$NOTIFY_STATE_FILE" ]]; then
    write_state "$NOTIFY_STATE_FILE" "$now" "$now" "$hard"
    return 0
  fi
  first=0; last=0; hardflag=0
  read -r first last hardflag < "$NOTIFY_STATE_FILE" || true
  [[ "$first"    =~ ^[0-9]+$ ]] || first="$now"
  [[ "$last"     =~ ^[0-9]+$ ]] || last=0
  [[ "$hardflag" =~ ^[01]$   ]] || hardflag=0
  # NOTIFY_REPEAT_SEC == 0 must mean "escalate once, then stay quiet". Without
  # the guard the comparison is trivially true and 0 would do the exact
  # opposite of every other 0 in this config: re-page on all 24 invocations.
  if (( hard == 1 )) && { (( hardflag == 0 )) \
       || (( NOTIFY_REPEAT_SEC > 0 && now - last >= NOTIFY_REPEAT_SEC )); }; then
    write_state "$NOTIFY_STATE_FILE" "$first" "$now" 1
    return 0
  fi
  write_state "$NOTIFY_STATE_FILE" "$first" "$last" "$hardflag"
  return 1
}

# The exit for every "this host cannot even attempt a backup" condition. Treated
# as hard from the first occurrence -- a broken config does not heal itself, and
# unlike an ordinary failure there is no next stage that might still succeed --
# but routed through the same throttle, so it pages once and then respects
# NOTIFY_REPEAT_HOURS instead of 24 times a day.
preflight_fail() {                     # preflight_fail MESSAGE
  log "FATAL: $1"
  echo "FATAL: $1" >&2
  ping_dms "$PING_URL/fail"
  if notify_should_push 1; then
    ntfy "$NTFY_TOPIC_HIGH" urgent rotating_light \
      "Backup BROKEN on $(hostname) (preflight)" \
"Host: $(hostname)
This host could not start a backup at all:

$1

Nothing was backed up, and nothing will be until this is fixed."
  elif (( REPORT_ONLY )); then
    log "NOTICE: diagnostic mode -- no alert sent, no notification state written"
  else
    log "NOTICE: notification suppressed (already alerted)"
  fi
  exit 1
}

# Armed here so that an unexpected failure in the config itself -- a command in
# it that fails under set -e, say -- is reported rather than swallowed. Replaced
# by the full ERR trap once notify_failure and the age arithmetic exist.
trap 'rc=$?; preflight_fail "unexpected failure while loading the config (line $LINENO, exit $rc)"' ERR

[[ -f "$CONFIG_DIR/config" ]] || preflight_fail "missing $CONFIG_DIR/config"
require_trusted "$CONFIG_DIR/config" "the config"
# Parse before executing: `source` on a half-written file aborts the shell part
# way through, leaving some settings applied and the rest at their defaults.
bash -n "$CONFIG_DIR/config" 2>/dev/null \
  || preflight_fail "$CONFIG_DIR/config is not valid bash (deploy or edit interrupted?)"
# shellcheck disable=SC1091
source "$CONFIG_DIR/config"
# NOTE: restic authenticates to rest-server via HTTP Basic Auth on EVERY request --
# there is no login step. Credentials come from RESTIC_REST_USERNAME / RESTIC_REST_PASSWORD
# (set in config), and are DISTINCT from RESTIC_PASSWORD_FILE (the encryption password).

# ---- Defaults + required-value guards ----
declare -p BACKUP_PATHS &>/dev/null || preflight_fail "BACKUP_PATHS is not set in $CONFIG_DIR/config"
(( ${#BACKUP_PATHS[@]} )) || preflight_fail "BACKUP_PATHS is empty in $CONFIG_DIR/config"
declare -p EXTRA_BACKUP_ARGS &>/dev/null || EXTRA_BACKUP_ARGS=()  # e.g. (--one-file-system)
declare -p UNBACKED_MOUNTS   &>/dev/null || UNBACKED_MOUNTS=()    # mounts deliberately not backed up
EXCLUDE_FILE="${EXCLUDE_FILE:-$CONFIG_DIR/excludes}"
EXCLUDE_FILE_LOCAL="${EXCLUDE_FILE_LOCAL:-$CONFIG_DIR/excludes.local}"
DUMP_DIR="${DUMP_DIR:-$CONFIG_DIR/db-dumps}"

# ---- Exclude arguments ----
# TWO files: the shared one deploy.sh pushes, then this host's own. The ORDER IS
# LOAD-BEARING. restic lets a later pattern override an earlier one, so a host
# keeps something the fleet-wide file drops by writing "!.venv" in excludes.local
# -- and that only works while the local file comes SECOND. Reversed, the base
# wins and the negation silently does nothing.
#
# A "!" can only take back a pattern that named the path ITSELF. restic follows
# gitignore here: an excluded DIRECTORY is never descended into, so
# "!a/b/keep" rescues nothing out of an excluded "a/b" -- the snapshot gets an
# empty "a", and there is no error to notice. To keep one child, exclude the
# CHILDREN and negate below that:
#     a/b/*
#     !a/b/keep
# (checked against restic 0.18.1 and 0.19.1)
#
# The local file is OPTIONAL and is passed ONLY when it is readable: restic exits
# 1 on an --exclude-file it cannot open, so passing it unconditionally would fail
# the backup on every host that has not written one -- which is all of them, the
# hour this ships.
declare -a EXCLUDE_ARGS=(--exclude-file "$EXCLUDE_FILE")
[[ -r "$EXCLUDE_FILE_LOCAL" ]] && EXCLUDE_ARGS+=(--exclude-file "$EXCLUDE_FILE_LOCAL")

# The two secrets are excluded here, built from $CONFIG_DIR, rather than written
# as literal paths into `excludes`. A written-out path is correct for exactly one
# CONFIG_DIR: on a host that sets a different one it matches nothing, and the
# encryption password lands in the repository that password unlocks -- silently,
# on an ordinary (/) backup, with no layer below that checks. Built here, the
# pair is right wherever CONFIG_DIR points, and `excludes` stays a file about
# regenerable junk that any host may edit freely.
#
# $DUMP_DIR sits in the same directory and MUST stay in the backup, which is why
# these are two named files and not the directory.
EXCLUDE_ARGS+=(--exclude "$CONFIG_DIR/encryption-pw" --exclude "$CONFIG_DIR/config")

# ...and refuse to start if this host has re-included either of them. A "!"
# pattern in an exclude FILE beats an --exclude on the command line, in either
# order (checked against restic 0.18), so the two lines above are drift-proof
# but not tamper-proof. The one case worth refusing outright is a host that
# takes its own encryption password back into the backup: that puts the key
# inside the repository the key unlocks, where it cannot help you and does hand
# the rest-server credentials and the ntfy token to anyone holding a single
# snapshot. Nothing downstream looks, and restore-time it is far too late.
if [[ -r "$EXCLUDE_FILE_LOCAL" ]]; then
  while IFS= read -r __line || [[ -n "$__line" ]]; do
    [[ "$__line" == '!'* ]] || continue
    __pat="${__line#!}"
    __pat="${__pat%"${__pat##*[![:space:]]}"}"          # drop trailing blanks
    if [[ "$__pat" == "$CONFIG_DIR/encryption-pw" || "$__pat" == "$CONFIG_DIR/config" ]]; then
      preflight_fail \
"$EXCLUDE_FILE_LOCAL re-includes $__pat with a \"!\" pattern.

That writes this client's own secret into the repository it unlocks. Delete the
line. If you genuinely need that file in a backup, it belongs in a different
repository, not this one."
    fi
  done < "$EXCLUDE_FILE_LOCAL"
  unset __line __pat
fi
LOCK_WAIT="${LOCK_WAIT:-15m}"
SKIP_IF_METERED="${SKIP_IF_METERED:-false}"

# Staleness. Hours; 0 disables that particular rule. WHEN a run is due is not
# configurable -- it is one success per local day, see SELF-SCHEDULING at the
# top of this file. These two only decide when a run of skips starts paging.
int_cfg MAX_BACKUP_AGE_HOURS 36                      # 0 = never hard-fail on age
int_cfg NOTIFY_REPEAT_HOURS  12                      # re-page interval while stale

# Version drift. REPORT ONLY -- this script never downloads or installs code.
# Knowing which host is running an old copy is the whole point; updating is
# deploy.sh's job, from a machine you are sitting at.
VERSION_CHECK_URL="${VERSION_CHECK_URL:-}"           # "" = disabled
int_cfg VERSION_CHECK_INTERVAL_HOURS 24

# WireGuard self-heal: bounce the tunnel if the backend is unreachable, at most
# once per WG_BOUNCE_INTERVAL_HOURS and never without a default route.
WG_INTERFACE="${WG_INTERFACE:-}"                     # "" = never touch the tunnel
WG_RESTART_CMD="${WG_RESTART_CMD:-}"                 # overrides the built-in logic
int_cfg WG_SETTLE_SECS 5                             # seconds, not hours
int_cfg WG_BOUNCE_INTERVAL_HOURS 6                   # 0 = bounce on every due run

# The three scheduling knobs are accepted-and-ignored rather than fatal: they
# sit in every config deployed so far, and a host must not stop backing up
# because its config still carries one.
for __obsolete in BACKUP_WINDOW MIN_INTERVAL_HOURS FORCE_AFTER_HOURS; do
  declare -p "$__obsolete" &>/dev/null || continue
  log "WARN: $__obsolete is obsolete and ignored -- the schedule is one successful"
  log "WARN: backup per local calendar day, retried hourly until it lands, and takes"
  log "WARN: no configuration. Delete it from $CONFIG_DIR/config."
done
unset __obsolete

if declare -p SKIP_IF_UNREACHABLE &>/dev/null; then
  log "WARN: SKIP_IF_UNREACHABLE is obsolete and ignored -- an unreachable backend is"
  log "WARN: now always a silent skip, and MAX_BACKUP_AGE_HOURS decides when that"
  log "WARN: becomes a failure. Delete it from $CONFIG_DIR/config."
fi

MAX_AGE_SEC=$(( MAX_BACKUP_AGE_HOURS * 3600 ))
NOTIFY_REPEAT_SEC=$(( NOTIFY_REPEAT_HOURS * 3600 ))
VERSION_CHECK_INTERVAL_SEC=$(( VERSION_CHECK_INTERVAL_HOURS * 3600 ))
WG_BOUNCE_INTERVAL_SEC=$(( WG_BOUNCE_INTERVAL_HOURS * 3600 ))

# The hard-fail threshold has to leave room for the schedule itself. Successive
# successes are ~24h apart on a healthy host, and a night the backend was down
# pushes the next one further: a failed 00:xx run that only lands at noon makes
# a ~36h gap with nothing wrong at either end. Anything at or below 24h pages
# about the schedule working as designed.
if (( MAX_AGE_SEC > 0 && MAX_BACKUP_AGE_HOURS <= 24 )); then
  log "WARN: MAX_BACKUP_AGE_HOURS ($MAX_BACKUP_AGE_HOURS) leaves no room for a once-a-day"
  log "WARN: schedule; expect alerts for backups that are not yet due. Use 30 or more."
fi

# The config is authoritative from here on: it has just overwritten whatever the
# pre-parse above guessed. Only the two derived names need re-deriving.
PING_URL="${RESTIC_PING_URL:-$PING_URL}"
NTFY_TOPIC_HIGH="${NTFY_TOPIC_HIGH:-backups-high}"
NTFY_TOPIC_LOW="${NTFY_TOPIC_LOW:-}"                 # "" = drift is log-only

# ---- Version drift -------------------------------------------------------
# Compares THIS FILE against the published one and says so. It does not fetch
# code to run, and deliberately has no path that writes to $SELF_PATH: the
# script runs as root on every host, so an auto-updater would turn one GitHub
# credential into fleet-wide root. Updating is a push from deploy.sh, by a
# human. See README section 10.
#
# Strictly advisory: it runs only AFTER a successful backup, every failure in
# here is swallowed, and nothing it does can delay or block a backup.
sha256_of() {
  if   command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" 2>/dev/null | awk '{print $1}'
  elif command -v openssl   >/dev/null 2>&1; then openssl dgst -sha256 "$1" 2>/dev/null | awk '{print $NF}'
  else return 1; fi
}

# state file: "<checked_epoch> <remote_sha> <notified_sha>"
_version_state() {
  local checked=0 remote="-" notified="-"
  if [[ -s "$VERSION_STATE_FILE" ]]; then
    read -r checked remote notified < "$VERSION_STATE_FILE" || true
    [[ "$checked" =~ ^[0-9]+$ ]] || checked=0
  fi
  printf '%s %s %s' "$checked" "${remote:--}" "${notified:--}"
}

version_check() {                      # $1 = "force" to ignore the interval
  [[ -n "$VERSION_CHECK_URL" ]] || return 0
  local now checked remote_sha notified_sha local_sha tmp
  now=$(date +%s)
  read -r checked remote_sha notified_sha <<<"$(_version_state)"
  if [[ "${1:-}" != force ]] && (( VERSION_CHECK_INTERVAL_SEC > 0 )) \
     && (( now - checked < VERSION_CHECK_INTERVAL_SEC )); then
    return 0
  fi
  local_sha="$(sha256_of "$SELF_PATH")" || { log "NOTICE: no sha256 tool; version check skipped"; return 0; }
  [[ -n "$local_sha" ]] || return 0
  tmp="$(mktemp 2>/dev/null)" || return 0
  if ! curl -fsS -m 20 "$VERSION_CHECK_URL" -o "$tmp" 2>/dev/null; then
    rm -f "$tmp"; log "NOTICE: version check could not reach $VERSION_CHECK_URL (ignored)"; return 0
  fi
  # A captive portal answers 200 with HTML, which -f will not catch.
  if ! head -n1 "$tmp" | grep -q '^#!/bin/bash'; then
    rm -f "$tmp"; log "NOTICE: version check got something that is not the script (ignored)"; return 0
  fi
  remote_sha="$(sha256_of "$tmp")" || { rm -f "$tmp"; return 0; }
  rm -f "$tmp"
  write_state "$VERSION_STATE_FILE" "$now" "$remote_sha" "$notified_sha"

  [[ "$local_sha" == "$remote_sha" ]] && return 0

  log "WARN: this host is NOT running the published version of restic-backup.sh"
  log "WARN:   local  ${local_sha:0:12}   remote ${remote_sha:0:12}   ($VERSION_CHECK_URL)"
  log "WARN:   deploy with ./deploy.sh -- this host will not update itself"
  # The REPORT_ONLY guard belongs here and not only inside ntfy(): what marks a
  # drift as notified is the write_state below, which sits NEXT TO the send
  # rather than inside it. Without this, `--check-update` reached an inert ntfy
  # and then recorded the drift as already announced, so the next real run --
  # the one that would actually have pushed -- stayed silent. That is the same
  # "diagnostic run spends the alert" failure the argument parsing guards
  # against for the urgent path, in the one place it does not inherit it.
  #
  # The cache write above still happens, deliberately: --check-update was asked
  # to go and look, so recording what it found is its job, and it leaves
  # notified_sha alone. The only cost is that it also refreshes `checked`, so a
  # real run inside VERSION_CHECK_INTERVAL_HOURS skips the re-check and the
  # push arrives with the next one -- delayed, not dropped.
  if [[ -n "$NTFY_TOPIC_LOW" && "$remote_sha" != "$notified_sha" ]] && (( ! REPORT_ONLY )); then
    ntfy "$NTFY_TOPIC_LOW" low arrows_counterclockwise \
      "Backup script out of date on $(hostname)" \
"Host:   $(hostname)
Local:  ${local_sha:0:12}
Remote: ${remote_sha:0:12}
Source: $VERSION_CHECK_URL

Nothing was changed -- deploy with ./deploy.sh."
    write_state "$VERSION_STATE_FILE" "$now" "$remote_sha" "$remote_sha"
  fi
  return 0
}

# One line for --status. Reads the last recorded result; never touches network.
version_status() {
  [[ -n "$VERSION_CHECK_URL" ]] || { printf 'check disabled (VERSION_CHECK_URL unset)'; return; }
  local checked remote notified local_sha
  read -r checked remote notified <<<"$(_version_state)"
  if (( checked == 0 )) || [[ "$remote" == "-" ]]; then printf 'not checked yet'; return; fi
  local_sha="$(sha256_of "$SELF_PATH")" || { printf 'unknown (no sha256 tool)'; return; }
  if [[ "$local_sha" == "$remote" ]]; then
    printf 'matches published (checked %s ago)' "$(fmt_age $(( $(date +%s) - checked )))"
  else
    printf 'DIFFERS from published -- local %s, remote %s' "${local_sha:0:12}" "${remote:0:12}"
  fi
}

# $4 is the age the hard/soft decision is made on. It defaults to the age of the
# last success, which is right for every failure except losing the lock, where
# the number that matters is how long the HOLDER has been running -- see
# stale_exit and the lock section.
notify_failure() {
  local stage="$1" code="$2" output="$3" age="${4:-$ALERT_AGE_SEC}" hard=0 last_txt="never"
  if (( MAX_AGE_SEC > 0 && age >= MAX_AGE_SEC )); then hard=1; fi

  # Did the machine sleep somewhere inside this run?
  local susp_now slept=0 susp_note=""
  susp_now="$(suspend_count)"
  if [[ -n "$SUSPENDS_AT_START" && -n "$susp_now" ]] && (( susp_now > SUSPENDS_AT_START )); then
    slept=1
    susp_note=$'\n''Slept: yes -- the machine suspended during this run'
  fi

  # A run the machine slept through is not a failure anyone can act on, so it is
  # logged and left to the hourly grid. Suspend takes the sockets restic is
  # holding with it, and against an append-only rest-server the retry that
  # follows the resume re-POSTs a pack the server already wrote and is answered
  # 403 -- a failure whose whole cause is that the lid closed. Nothing is
  # damaged: the packs left with no snapshot pointing at them are orphans the
  # maintenance host's prune collects, and the next hourly run backs up normally.
  #
  # Bounded by $hard deliberately. Past MAX_BACKUP_AGE_HOURS the reason stops
  # mattering -- a host that has not backed up in that long is actionable however
  # good its excuse -- and without the bound a machine that sleeps through its
  # backup EVERY day would go quiet permanently, which is the one outcome the
  # staleness alarm exists to prevent. Above that line the suspend is reported
  # rather than swallowed: $susp_note puts it in the push, where "and it slept
  # through all of them" is the diagnosis.
  #
  # MAX_BACKUP_AGE_HOURS=0 therefore makes this unbounded, since $hard can never
  # become 1. That is the documented meaning of 0 -- the local staleness alarm is
  # off and the external dead-man's switch is the backstop -- and the switch
  # still catches it: a host that sleeps through every attempt stops pinging
  # success, which is exactly the silence a DMS is watching for.
  #
  # Neither the dead-man's switch nor $NOTIFY_STATE_FILE is touched here.
  # Pinging /fail would move the page to the DMS instead of retiring it, and
  # leaving the notify state alone is what keeps the NEXT failure -- a real one,
  # on a run nothing interrupted -- the "first failure after a success" that
  # always pushes, rather than a later one in a streak that stays quiet.
  if (( slept == 1 && hard == 0 )); then
    log "NOTICE: '$stage' failed (exit $code) across a suspend; not actionable, retrying next hour."
    return 0
  fi

  ping_dms "$PING_URL/fail"
  if (( ${LAST_SUCCESS:-0} > 0 )); then last_txt="$(date -d "@$LAST_SUCCESS" '+%Y-%m-%d %H:%M') ($(fmt_age "$ALERT_AGE_SEC") ago)"; fi
  if ! notify_should_push "$hard"; then
    if (( REPORT_ONLY )); then
      log "NOTICE: '$stage' failed (exit $code); diagnostic mode -- no alert sent"
    else
      # $age, not $ALERT_AGE_SEC: the hard/soft decision just above was made on
      # $age, and on the lock path they are different numbers -- stale_exit
      # passes the HOLDER's age there, precisely because .last-success
      # describes a run that already finished, not the one still going.
      log "NOTICE: '$stage' failed (exit $code); notification suppressed (already alerted, age $(fmt_age "$age"))"
    fi
    return 0
  fi
  ntfy "$NTFY_TOPIC_HIGH" urgent rotating_light \
    "Backup FAILED on $(hostname) ($stage)" \
"Host:  $(hostname)
Stage: $stage
Exit:  $code${susp_note}
Last good backup: $last_txt
$(printf '%s' "$output" | tail -c 1500)"
  command -v notify-send >/dev/null 2>&1 \
    && notify-send -u critical "restic backup failed" "$stage (exit $code)" 2>/dev/null || true
}

# Runs one stage, streaming its output to the log AS IT HAPPENS while keeping a
# copy for the failure notification. Streamed rather than captured into a
# variable and printed afterwards, because the one case the lock-staleness alarm
# exists for -- a `restic backup` wedged on a half-open WireGuard connection --
# would then log the ">>> backup" line and nothing at all for a day and a half,
# and killing that run takes the buffer with it, leaving nothing to diagnose.
#
# 9>&- keeps the lock fd out of the child. Anything a pre-backup hook leaves
# running in the background would otherwise inherit the flock and hold it for
# good: every later run would report "another run has held the lock for Nh",
# page once past MAX_BACKUP_AGE_HOURS, and never back up again.
#
# It is needed on BOTH halves of the pipeline: a redirection before the pipe
# applies only to the first element, so a tee that inherited fd 9 held the lock
# just as effectively as the hook's own orphan -- and outlived the run that
# started it, since a background hook holding the pipe open keeps tee alive
# after this script is killed.
run_step() {
  local stage="$1"; shift
  local tmp rc out
  log ">>> $stage"
  tmp="$(mktemp 2>/dev/null)" || tmp=""      # 0600; /tmp is excluded from backups
  set +e
  if [[ -n "$tmp" ]]; then
    "$@" 9>&- 2>&1 | tee "$tmp" 9>&-
    rc=${PIPESTATUS[0]}
  else
    "$@" 9>&- 2>&1
    rc=$?
  fi
  set -e
  if (( rc != 0 )); then
    log "ERROR during '$stage' (exit $rc)"
    out="$(tail -c 1500 "$tmp" 2>/dev/null)"
    rm -f "$tmp"
    notify_failure "$stage" "$rc" "${out:-see journal/log}"
    exit "$rc"
  fi
  rm -f "$tmp"
}

trap 'rc=$?; log "ERROR: unexpected failure (line $LINENO, exit $rc)"; notify_failure script "$rc" "see journal/log"; exit $rc' ERR

# ============================================================================
#  DATABASE DUMPS  --  per-host SELECTION lives in the config via these arrays:
#
#     MARIADB_LOCAL=(db1 db2)   or   (ALL)      # local MariaDB/MySQL
#     POSTGRES_LOCAL=(db1)      or   (ALL)      # local PostgreSQL
#     DOCKER_AUTO=(container ...)               # detect engine + dump EVERYTHING
#     SQLITE_FILES=(name:/path/to.db ...)       # SQLite (can't be auto-detected)
#
#  ALL  -> one combined dump (mariadb --all-databases / pg_dumpall).
#  names-> one file per database.
#  Credentials: local via ~/.my.cnf / ~/.pgpass / peer auth; docker reads each
#  container's OWN environment, so you only name the container.
# ============================================================================

_slug() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }

# Run a command, send STDOUT to $DUMP_DIR/<name>.sql atomically. On failure (or
# empty output) notify and abort the whole backup -- the policy throughout here:
# better no backup than a backup with a half-dumped database.
db_dump_to() {
  local name; name="$(_slug "$1")"; shift
  local out="$DUMP_DIR/$name.sql" tmp="$DUMP_DIR/$name.sql.tmp" err="$DUMP_DIR/$name.sql.err"
  log ">>> dump $name"
  # 9>&- for the same reason run_step closes it: these are config-supplied
  # commands (docker exec, sudo -u postgres pg_dump ...), so anything one of
  # them leaves running in the background would inherit the flock and hold it
  # for good -- every later run would report "another run has held the lock for
  # Nh" and never back up again.
  set +e; "$@" 9>&- >"$tmp" 2>"$err"; local rc=$?; set -e
  if (( rc != 0 )) || [[ ! -s "$tmp" ]]; then
    local why; if (( rc != 0 )); then why="exit $rc"; else why="empty output"; rc=1; fi
    local msg; msg="$(tail -c 800 "$err" 2>/dev/null)"
    rm -f "$tmp" "$err"
    notify_failure "dump:$name" "$rc" "${msg:-$why}"
    exit "$rc"
  fi
  rm -f "$err"; mv -f "$tmp" "$out"
}

# ---- local MariaDB / MySQL -------------------------------------------------
db_mariadb_local() {                          # ALL | db [db ...]
  if [[ "${1:-}" == "ALL" ]]; then
    db_dump_to "mariadb-all" \
      mariadb-dump --single-transaction --quick --routines --events --all-databases
  else
    local db
    for db in "$@"; do
      db_dump_to "mariadb-$db" \
        mariadb-dump --single-transaction --quick --routines --events "$db"
    done
  fi
}

# ---- local PostgreSQL (needs root/postgres or NOPASSWD sudo) ---------------
db_postgres_local() {                         # ALL | db [db ...]
  if [[ "${1:-}" == "ALL" ]]; then
    db_dump_to "pg-all" sudo -n -u postgres pg_dumpall
  else
    db_dump_to "pg-globals" sudo -n -u postgres pg_dumpall --globals-only
    local db
    for db in "$@"; do
      db_dump_to "pg-$db" sudo -n -u postgres pg_dump --create "$db"
    done
  fi
}

# ---- SQLite on the host filesystem -----------------------------------------
db_sqlite_file() {                            # name:/path/to.db
  local name="${1%%:*}" path="${1#*:}"
  [[ -r "$path" ]] || { notify_failure "dump:sqlite-$name" 1 "sqlite db not readable: $path"; exit 1; }
  db_dump_to "sqlite-$name" sqlite3 "$path" .dump
}

# ---- Docker: detect the engine INSIDE the container, dump EVERYTHING --------
# You only name the container. The dump tool is discovered in the container, all
# databases are dumped, and the password (if any) is taken from the container's
# own environment -- so it is never visible on the host process list.
db_docker_auto() {                            # container
  local cont="$1" engine
  engine="$(docker exec "$cont" sh -c '
      if   command -v mariadb-dump >/dev/null 2>&1; then echo mariadb
      elif command -v mysqldump    >/dev/null 2>&1; then echo mysql
      elif command -v pg_dumpall   >/dev/null 2>&1; then echo postgres
      else echo unknown; fi' 2>/dev/null)" || engine=unreachable

  case "$engine" in
    mariadb|mysql)
      local tool=mariadb-dump; [[ "$engine" == "mysql" ]] && tool=mysqldump
      db_dump_to "docker-$cont-all" \
        docker exec "$cont" sh -c '
          : "${MARIADB_ROOT_PASSWORD:=${MYSQL_ROOT_PASSWORD:-}}"
          [ -n "$MARIADB_ROOT_PASSWORD" ] && export MYSQL_PWD="$MARIADB_ROOT_PASSWORD"
          exec "$1" --single-transaction --quick --routines --events --all-databases -uroot
        ' _ "$tool"
      ;;
    postgres)
      db_dump_to "docker-$cont-all" \
        docker exec "$cont" sh -c '
          [ -n "${POSTGRES_PASSWORD:-}" ] && export PGPASSWORD="$POSTGRES_PASSWORD"
          exec pg_dumpall -U "${POSTGRES_USER:-postgres}"
        '
      ;;
    unknown)
      notify_failure "dump:docker-$cont" 1 \
        "No mariadb-dump/mysqldump/pg_dumpall in container '$cont'. For SQLite, list the file under SQLITE_FILES instead."
      exit 1 ;;
    *)
      notify_failure "dump:docker-$cont" 1 "Container '$cont' is not running / not reachable for dump"
      exit 1 ;;
  esac
}

# ---- driver: run everything declared in config -----------------------------
run_db_dumps() {
  if declare -p MARIADB_LOCAL  &>/dev/null && (( ${#MARIADB_LOCAL[@]} ));  then db_mariadb_local  "${MARIADB_LOCAL[@]}";  fi
  if declare -p POSTGRES_LOCAL &>/dev/null && (( ${#POSTGRES_LOCAL[@]} )); then db_postgres_local "${POSTGRES_LOCAL[@]}"; fi
  local x
  if declare -p DOCKER_AUTO    &>/dev/null && (( ${#DOCKER_AUTO[@]} ));    then for x in "${DOCKER_AUTO[@]}";  do db_docker_auto "$x"; done; fi
  if declare -p SQLITE_FILES   &>/dev/null && (( ${#SQLITE_FILES[@]} ));   then for x in "${SQLITE_FILES[@]}"; do db_sqlite_file "$x"; done; fi
}

# true if any DB-dump array is declared and non-empty
_have_db_config() {
  local v ref
  for v in MARIADB_LOCAL POSTGRES_LOCAL DOCKER_AUTO SQLITE_FILES; do
    declare -p "$v" &>/dev/null || continue
    declare -n ref="$v"; (( ${#ref[@]} )) && return 0
  done
  return 1
}

# ============================================================================
#  SOURCE PREFLIGHT  --  the two ways this script can report a healthy backup
#  that contains nothing.
#
#  1. A source path that exists but has nothing in it. A mountpoint whose
#     filesystem failed to mount (an unlocked-at-boot LUKS volume, an NFS server
#     that was down, a USB disk nobody plugged in) is an ordinary empty
#     directory. restic snapshots it, exits 0, .last-success is written and the
#     dead-man's switch gets a success ping. A path that does not exist at all is
#     safe -- restic fails with exit 3 -- so it is only this case that is silent.
#
#  2. --one-file-system, which is what config.sample recommends for a (/) backup.
#     It stops restic wandering into a USB disk, and it stops it just as quietly
#     at /home, /var or /srv when those are separate logical volumes, which is
#     the normal LVM and cloud-image layout. The snapshot then holds the root
#     filesystem and nothing else, and says so nowhere.
#
#  Both are fatal rather than a warning: the whole point is that they currently
#  look like success, and a run that backs up an empty directory is worse than
#  one that does not run at all. A mount that genuinely should not be backed up
#  is declared in UNBACKED_MOUNTS and stops being reported.
# ============================================================================

# Filesystem types that hold nothing worth a snapshot. squashfs is here for
# snap/AppImage loop mounts: read-only images, re-fetchable, and the files they
# are built from live under / and are backed up.
PSEUDO_FSTYPES="proc sysfs devtmpfs devpts tmpfs ramfs cgroup cgroup2 securityfs
debugfs tracefs pstore bpf configfs fusectl mqueue hugetlbfs autofs binfmt_misc
efivarfs nsfs rpc_pipefs selinuxfs squashfs overlay fuse.gvfsd-fuse fuse.portal"

is_mountpoint() {                      # path -> 0 if a filesystem is mounted there
  local p="$1" d pd
  d=$(stat -c %d "$p"    2>/dev/null) || return 1
  pd=$(stat -c %d "$p/.." 2>/dev/null) || return 1
  [[ "$d" != "$pd" ]] && return 0
  [[ "$(readlink -f "$p")" == / ]]     # / is its own parent
}

one_file_system_in_use() {
  local a
  for a in ${EXTRA_BACKUP_ARGS+"${EXTRA_BACKUP_ARGS[@]}"}; do
    [[ "$a" == "--one-file-system" || "$a" == "-x" ]] && return 0
  done
  return 1
}

# Anchored, literal exclude patterns, which is all this needs to recognise the
# pseudo-filesystem entries. Wildcards and unanchored names are skipped: at
# worst a deliberately excluded mount is reported as a gap, which is a loud and
# one-line-of-config fixable answer, not a silent one.
excluded_prefixes() {
  local f
  for f in "$EXCLUDE_FILE" "$EXCLUDE_FILE_LOCAL"; do
    [[ -r "$f" ]] || continue
    grep -E '^/[^*?[]*$' "$f" 2>/dev/null | sed 's:/\+$::' || true
  done
}

# PATH is deliberately closed (see the top of this file), so "restic is
# installed" and "restic is reachable from here" are different questions -- a
# snap or /opt install answers yes to the first and no to the second. Asking now
# turns an exit 127 in the middle of a run into one clear, throttled page.
check_restic_present() {
  command -v restic >/dev/null 2>&1 || preflight_fail \
"restic is not on this script's PATH ($PATH).
If it is installed somewhere else -- /snap/bin, /opt, a Go workspace -- add that
directory from $CONFIG_DIR/config, which is sourced with a verified owner:
    export PATH=\"/snap/bin:\$PATH\""
}

# curl is as load-bearing here as restic and flock, and was the only one of the
# three never checked. All THREE of the things that make a skip safe go through
# it: REST_HEALTH_URL (backend_reachable), RESTIC_PING_URL (the dead-man's
# switch) and NTFY_URL (the page). Miss it and backend_reachable fails on every
# run, so every run stale_exit()s -- and neither the local alert nor the DMS
# ping can be sent to say why. The host stops backing up, the only local trace
# is a log line, and detection falls back to the external switch noticing an
# absence a grace period later: exactly the outcome the local alerting exists
# to replace.
#
# Checked only where it is actually used, since a host with none of the three
# configured genuinely does not need it.
check_curl_present() {
  [[ -n "${REST_HEALTH_URL:-}${PING_URL}${NTFY_URL}" ]] || return 0
  command -v curl >/dev/null 2>&1 || preflight_fail \
"curl is not on this script's PATH ($PATH), and this host is configured to use
it: REST_HEALTH_URL, RESTIC_PING_URL and NTFY_URL all go through curl.
Without it the backend always reads as unreachable, so every run skips -- and
neither the local alert nor the dead-man's-switch ping can report that.
Install curl, or add its directory from $CONFIG_DIR/config:
    export PATH=\"/opt/bin:\$PATH\""
}

check_backup_sources() {
  local p
  for p in "${BACKUP_PATHS[@]}"; do
    [[ -e "$p" ]] || preflight_fail \
"BACKUP_PATHS lists $p, which does not exist.
Fix the path in $CONFIG_DIR/config, or create/mount it."
    [[ -d "$p" ]] || continue
    # A mounted-but-empty filesystem is a real (if odd) state; an empty
    # directory that is NOT a mountpoint is what a failed mount looks like.
    is_mountpoint "$p" && continue
    [[ -n "$(find "$p" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]] || preflight_fail \
"BACKUP_PATHS lists $p, which exists but is empty and is not a mountpoint.
This is what a filesystem that failed to mount looks like, and backing it up
would record an empty directory as a successful backup. Mount it, or remove it
from BACKUP_PATHS."
  done
}

# What --status says about coverage. A host with a live gap is producing
# INCOMPLETE backups while .last-success updates normally, so "stale : no" and
# exit 0 are both true and both beside the point -- without this line the fleet
# view could not see the condition at all.
#
# Reported, NOT folded into the exit code, and the two are different on purpose.
# The staleness gate exists because a host that is not running cron cannot page:
# there is no process left to do it. A mount gap is the opposite -- it pages
# urgently when the set appears, again whenever it changes, then every
# NOTIFY_REPEAT_HOURS. It is the loudest condition here, so this is a visibility
# gap, not an alerting one. Making it red would also leave deploy.sh --check red
# until someone hand-edited the config on that host -- a gate wedged open on
# manual intervention, which is what this condition must not become.
#
# Reads what the last due run recorded rather than re-scanning /proc/self/mounts:
# --status must stay cheap and side-effect-free, and the age says how fresh the
# answer is.
mount_gap_status() {
  local last=0 seen="" n when=""
  one_file_system_in_use || { printf -- '--one-file-system not in use'; return; }
  # No state file at all means no due run has scanned yet -- a fresh deploy
  # whose first run the backend may still be refusing. Distinct from a run
  # that looked and found nothing, which records an empty set below.
  [[ -s "$MOUNT_GAP_FILE" ]] || { printf 'not yet checked (no due run since deploy)'; return; }
  read -r last seen < "$MOUNT_GAP_FILE" || true
  [[ "$last" =~ ^[0-9]+$ ]] || last=0
  if (( last > 0 )); then when=" as of $(fmt_age $(( NOW - last ))) ago"; fi
  if [[ -z "$seen" ]]; then
    printf 'all mounts covered%s' "$when"
  else
    n=$(wc -w <<<"$seen")
    printf '%s SKIPPED by --one-file-system%s: %s' "$n" "$when" "$seen"
  fi
}

# Throttle for the coverage alert below. It cannot use $NOTIFY_STATE_FILE: that
# one is removed on every success, and these runs DO succeed -- the gap does not
# stop the backup -- so it would page on all 24 invocations a day. Keyed on the
# SET of gaps instead, so a new mount appearing is its own event rather than
# being swallowed by the repeat interval. State: "<epoch> <key>".
#
# Pages when the set first appears, whenever it changes, and then at most every
# NOTIFY_REPEAT_HOURS (0 = never again), matching notify_should_push's policy.
mount_gap_should_push() {              # mount_gap_should_push KEY
  (( REPORT_ONLY )) && return 1
  local key="$1" last=0 seen=""
  if [[ -s "$MOUNT_GAP_FILE" ]]; then
    read -r last seen < "$MOUNT_GAP_FILE" || true
    [[ "$last" =~ ^[0-9]+$ ]] || last=0
  fi
  # A $last in the future (clock skew) suppresses until it passes, which is the
  # quiet choice -- the same one lock_held_secs makes for an unreadable mtime.
  if [[ "$seen" == "$key" ]] \
     && { (( NOTIFY_REPEAT_SEC <= 0 )) || (( NOW - last < NOTIFY_REPEAT_SEC )); }; then
    return 1
  fi
  write_state "$MOUNT_GAP_FILE" "$NOW" "$key"
  return 0
}

# Every local mount that --one-file-system will silently decline to cross.
check_one_file_system_coverage() {
  one_file_system_in_use || return 0
  # Two parallel arrays, not one "path (fstype)" string per gap: mount targets
  # can contain spaces (/proc/self/mounts escapes them as \040, and the
  # printf '%b' below turns that back into a real space), so the packed form
  # could not be taken apart again to build the UNBACKED_MOUNTS suggestion.
  local -a gap_targets=() gap_labels=() ex_prefixes=()
  local target fstype p root best t_dev p_dev ex covered pseudo
  mapfile -t ex_prefixes < <(excluded_prefixes)
  pseudo=" ${PSEUDO_FSTYPES//[$'\n\t']/ } "          # whole-word matching, not substring

  while read -r _ target fstype _; do
    target="$(printf '%b' "$target")"
    [[ "$pseudo" == *" $fstype "* ]] && continue

    # Which backup root would have to reach this mount? Longest match wins.
    best=""
    for p in "${BACKUP_PATHS[@]}"; do
      root="${p%/}"; root="${root:-/}"
      [[ "$target" == "$root" || "$target" == "$root"/* || "$root" == / ]] || continue
      (( ${#root} > ${#best} )) && best="$root"
    done
    [[ -n "$best" ]] || continue                       # outside the backup set entirely

    covered=0
    for p in "${BACKUP_PATHS[@]}"; do
      [[ "${p%/}" == "${target%/}" ]] && { covered=1; break; }   # restic is given it directly
    done
    for ex in ${UNBACKED_MOUNTS+"${UNBACKED_MOUNTS[@]}"}; do
      [[ "${ex%/}" == "${target%/}" ]] && { covered=1; break; }  # declared as not wanted
    done
    for ex in ${ex_prefixes+"${ex_prefixes[@]}"}; do
      [[ -n "$ex" && ( "$target" == "$ex" || "$target" == "$ex"/* ) ]] && { covered=1; break; }
    done
    (( covered )) && continue

    # A bind mount inside the same filesystem shares the device id, and
    # --one-file-system compares device ids -- restic crosses it happily.
    t_dev=$(stat -c %d "$target" 2>/dev/null) || continue
    p_dev=$(stat -c %d "$best"   2>/dev/null) || continue
    [[ "$t_dev" == "$p_dev" ]] && continue

    gap_targets+=("$target")
    gap_labels+=("$target  ($fstype)")
  done < /proc/self/mounts

  if (( ! ${#gap_targets[@]} )); then
    # Records the CLEAN SCAN rather than removing the file. "No file" and
    # "looked, found nothing" are different claims, and with the file gone
    # --status cannot tell them apart: it reads a freshly deployed host as
    # "all mounts covered" before any due run has scanned it, and a backend
    # that is down holds that off for as long as it stays down. Reporting
    # healthy without having looked is the one claim this must never make.
    #
    # An empty set still makes a recurrence page at once -- deleting the file
    # would give that too, and this keeps it: mount_gap_should_push compares
    # SETS, and any gap differs from
    # none, so the repeat interval is not inherited from the last occurrence.
    (( REPORT_ONLY )) || write_state "$MOUNT_GAP_FILE" "$NOW" ""
    return 0
  fi

  # This ALERTS; it deliberately does not abort. Calling preflight_fail here,
  # which exits, would turn a transient mount inside the backup set that is not
  # under /mnt, /media or /run (a one-off NFS share at /srv/incoming, a
  # loop-mounted image, a btrfs subvolume an update created) into no backup AT
  # ALL on every subsequent hourly run, with no operator override: --force does
  # not reach past here either. The state being defended against -- a snapshot
  # missing one mount -- is strictly better than the state that would produce:
  # no snapshot, of anything, until someone hand-edits the config on that host.
  #
  # So: back up what we can, and make the gap as loud as the abort was. Urgent
  # priority, the same throttle policy, and stderr as well as the log, because
  # the point of the original gate stands -- the flag's omissions are invisible
  # at restore time, and nothing else on this host will mention them.
  # %q so a path with a space is pasteable as ONE array element -- and, since %q
  # leaves no literal spaces behind, the set doubles as a single-line state key.
  local suggestion key body
  suggestion="$(printf '%q ' "${gap_targets[@]}")"
  key="${suggestion% }"
  body="--one-file-system is in EXTRA_BACKUP_ARGS, and these mounted filesystems are
inside the backup set and are being SKIPPED:

$(printf '  %s\n' "${gap_labels[@]}")

Each one is missing from every snapshot, with no error at restore time.
Either add it to BACKUP_PATHS in $CONFIG_DIR/config, exclude it in
$EXCLUDE_FILE_LOCAL, or -- if it really should not be backed up -- acknowledge it:

  UNBACKED_MOUNTS=($key)"

  log "WARN: --one-file-system is skipping ${#gap_targets[@]} mounted filesystem(s): ${gap_labels[*]}"
  printf 'WARNING: %s\n' "$body" >&2
  if mount_gap_should_push "$key"; then
    ntfy "$NTFY_TOPIC_HIGH" urgent file_folder \
      "Backup INCOMPLETE on $(hostname) (mounts skipped)" \
"Host: $(hostname)
The backup is still running -- but it does not contain everything.

$body"
  elif (( REPORT_ONLY )); then
    log "NOTICE: diagnostic mode -- no alert sent, no notification state written"
  else
    log "NOTICE: notification suppressed (already alerted about this exact set)"
  fi
}

# ============================================================================
#  SCHEDULING GATE  --  "is this hour the moment?"
#
#  The decision is TODAY vs the day of the last success. The ages below are
#  what the log lines and the staleness alarm are phrased in; neither of them
#  decides anything about the schedule.
#
#  Two different ages, deliberately:
#    SCHED_AGE_SEC  time since the last SUCCESS; -1 means there has never been
#                   one, and a fresh install backs up on its first invocation
#                   rather than waiting for the coming midnight.
#    ALERT_AGE_SEC  the same, but measured from .first-seen when there has never
#                   been a success -- otherwise a host installed this morning
#                   would page you as "36h stale" on day one.
# ============================================================================
NOW=$(date +%s)
LAST_SUCCESS=$(read_epoch "$LAST_SUCCESS_FILE")
FIRST_SEEN=$(read_epoch "$FIRST_SEEN_FILE")
(( FIRST_SEEN > 0 )) || FIRST_SEEN=$NOW

# Seeded HERE, before the diagnostic modes return -- not after the flock, which
# only a real cron run ever reaches.
#
# It is the one state write --status is allowed to make, and the REPORT_ONLY
# rule above is about not CONSUMING anything: the notification one-shot, the
# DMS ping, the version-drift notice. This starts a clock, it does not spend
# one, and without it --status on a host that has never backed up recomputes
# FIRST_SEEN=$NOW on every single call. ALERT_AGE_SEC is then 0 forever and the
# host reports "stale : no", exit 0 -- so deploy.sh --check passes it green
# indefinitely. Precisely on the host where cron never fires at all (crond
# stopped, or the /etc/cron.d file rejected -- the failure the dot-in-filename
# guard and the restic-backup.cron header exist for), which is the one state
# the exit-3 gate exists to catch -- and, without this write, cannot see.
if [[ ! -s "$FIRST_SEEN_FILE" ]]; then write_state "$FIRST_SEEN_FILE" "$FIRST_SEEN"; fi

# The schedule, in two strings. Both days come from $NOW rather than from a
# second call to date(1), so a run that starts a microsecond before midnight
# cannot compare one day against the other's.
#
# A clock pushed forward and corrected leaves .last-success dated tomorrow:
# that reads as "a different day", so the host is due, backs up, and stamps
# today over it -- the self-repair an interval in hours needs an explicit rule
# for is just the ordinary path here.
TODAY="$(date -d "@$NOW" '+%Y-%m-%d')"
LAST_SUCCESS_DAY=""

if (( LAST_SUCCESS > 0 )); then
  LAST_SUCCESS_DAY="$(date -d "@$LAST_SUCCESS" '+%Y-%m-%d')"
  SCHED_AGE_SEC=$(( NOW - LAST_SUCCESS ))
  if (( SCHED_AGE_SEC < 0 )); then
    log "WARN: .last-success lies in the future (clock skew?); treating as just-run."
    SCHED_AGE_SEC=0
  fi
  ALERT_AGE_SEC=$SCHED_AGE_SEC
else
  SCHED_AGE_SEC=-1
  ALERT_AGE_SEC=$(( NOW - FIRST_SEEN ))
  if (( ALERT_AGE_SEC < 0 )); then ALERT_AGE_SEC=0; fi
fi

# Every exit path that did NOT back up comes through here -- except losing the
# flock, which is measured against the holder's age instead (see the lock
# section) -- so that a host which quietly stops backing up still alerts,
# locally, without waiting on the external dead-man's switch. Both paths use
# MAX_BACKUP_AGE_HOURS; they differ only in which age they compare against.
# Exits 1 when stale (a real failure), else 0.
# $2 is the age to judge, defaulting to the age of the last success. The lock
# path passes the holder's age instead, and it is threaded through as an
# argument rather than re-derived here: judging against ALERT_AGE_SEC gives the
# same answer today -- a holder cannot have written .last-success yet, so the
# last success is always at least as old as the lock -- but it would contradict
# the comments either side of this, and any change to .first-seen handling, or
# forward clock skew, would turn the documented "page when the holder is wedged"
# into a silent exit 0.
stale_exit() {
  local reason="$1" age="${2:-$ALERT_AGE_SEC}"
  if (( MAX_AGE_SEC > 0 && age >= MAX_AGE_SEC )); then
    # Phrased for both callers: on the lock path $age is how long the holder has
    # been running, which is equally "this long without a completed backup".
    log "STALE: $(fmt_age "$age") without a completed backup (limit ${MAX_BACKUP_AGE_HOURS}h)."
    notify_failure "stale: $reason" 1 \
"$(fmt_age "$age") without a completed backup -- limit is ${MAX_BACKUP_AGE_HOURS}h.
This run did not back up: $reason" "$age"
    exit 1
  fi
  exit 0
}

# Due until it works, then done for the day: the day stamp only moves when a
# backup actually SUCCEEDS (.last-success is written at the end of a good run,
# nowhere else), so a failed 00:xx attempt leaves this true and the 01:xx cron
# invocation finds the same answer. That is the whole hourly retry -- there is
# no retry counter and no backoff, because the hour grid already is one.
DUE_REASON=""
if (( FORCE )); then
  DUE_REASON="forced ($FORCE_SOURCE)"
elif [[ -z "$LAST_SUCCESS_DAY" ]]; then
  DUE_REASON="no successful backup on record"
elif [[ "$LAST_SUCCESS_DAY" != "$TODAY" ]]; then
  DUE_REASON="nothing backed up yet today; last success $LAST_SUCCESS_DAY ($(fmt_age "$SCHED_AGE_SEC") ago)"
fi

if (( STATUS_ONLY )); then
  if (( LAST_SUCCESS > 0 )); then
    printf 'last success : %s (%s ago)\n' "$(date -d "@$LAST_SUCCESS" '+%Y-%m-%d %H:%M:%S')" "$(fmt_age "$SCHED_AGE_SEC")"
  else
    printf 'last success : never (first seen %s, %s ago)\n' "$(date -d "@$FIRST_SEEN" '+%Y-%m-%d %H:%M:%S')" "$(fmt_age "$ALERT_AGE_SEC")"
  fi
  printf 'schedule     : one success per local day  (today %s, last success day %s)\n' \
    "$TODAY" "${LAST_SUCCESS_DAY:-never}"
  printf 'thresholds   : hard-fail %sh, re-page %sh\n' \
    "$MAX_BACKUP_AGE_HOURS" "$NOTIFY_REPEAT_HOURS"
  printf 'stale        : %s\n' \
    "$( (( MAX_AGE_SEC > 0 && ALERT_AGE_SEC >= MAX_AGE_SEC )) && echo 'YES -- would alert' || echo no )"
  printf 'mounts       : %s\n' "$(mount_gap_status)"
  printf 'version      : %s\n' "$(version_status)"
  printf 'decision     : %s\n' "${DUE_REASON:-not due -- already backed up today}"
  # Exit 3, not 0, when this host is past MAX_BACKUP_AGE_HOURS. --status is the
  # only way to ask a host "are you healthy?" without touching anything, and
  # deploy.sh --check runs it fleet-wide from CI; a mode that answered "stale:
  # YES -- would alert" and exited 0 made that gate pass on exactly the hosts
  # it exists to catch. Still no side effects -- only the code changes.
  (( MAX_AGE_SEC > 0 && ALERT_AGE_SEC >= MAX_AGE_SEC )) && exit 3
  exit 0
fi

if (( CHECK_UPDATE_ONLY )); then
  version_check force
  printf 'version : %s\n' "$(version_status)"
  exit 0
fi

# ---- Single-instance lock ----
# A backup that runs longer than an hour meets the next invocation head-on.
# The newcomer must NOT judge the holder by .last-success: the holder has not
# written it yet, so after a week offline that file is a week old and
# stale_exit() would page "Backup FAILED" about the catch-up run that is at
# that moment working perfectly -- and the first run after a week offline is
# exactly such a run. Judge the HOLDER instead, by how long it has held the
# lock: that is the only number here that says anything about its
# health. Still running past MAX_BACKUP_AGE_HOURS is not a slow backup, it is
# a wedged one, and that does deserve a page.
lock_held_secs() {                     # seconds since the holder took the lock
  local mt d
  mt=$(stat -c %Y "$LOCK_FILE" 2>/dev/null || true)
  [[ "$mt" =~ ^[0-9]+$ ]] || mt=$NOW   # unknown -> treat as "just started", stay quiet
  d=$(( NOW - mt ))
  (( d > 0 )) || d=0                   # clock skew
  printf '%s' "$d"
}
# No flock, no run -- fatal, rather than running unlocked, because a host
# without util-linux would otherwise get no locking at all with nothing saying
# so. An hourly backup that overruns the hour then meets the next invocation
# head-on, and the newcomer's cleanup_dumps() wipes $DUMP_DIR out from under the
# run in progress -- which finishes and reports success, minus every database
# dump. A missing lock is not a safe degradation of a backup script.
command -v flock >/dev/null 2>&1 || preflight_fail \
"flock is missing (install util-linux), so this run cannot take the
single-instance lock. Two overlapping runs would wipe each other's database
dumps mid-backup, and the survivor would still report success."

exec 9>>"$LOCK_FILE"                   # append, NOT truncate: opening it must not
                                       # reset the mtime we are about to read
if flock -n 9; then
  touch "$LOCK_FILE" 2>/dev/null || true      # mtime = when THIS run took the lock
else
  held="$(lock_held_secs)"
  log "Another run has held the lock for $(fmt_age "$held"); exiting."
  if (( MAX_AGE_SEC > 0 && held >= MAX_AGE_SEC )); then
    stale_exit "another run has been stuck for $(fmt_age "$held")" "$held"
  fi
  exit 0
fi

if [[ -z "$DUE_REASON" ]]; then
  log "Not due (already backed up today, $(fmt_age "$SCHED_AGE_SEC") ago); exiting."
  stale_exit "already backed up today"
fi
log "Due: $DUE_REASON"

# Only on a run that is actually going to back up: a source that is missing or
# unmounted is a reason to page, but not a reason to page on an hour we were
# going to skip anyway.
check_restic_present
check_curl_present
check_backup_sources
check_one_file_system_coverage

# ---- Network gate ----
# Only knob left: skip metered links (cellular cost). Reachability of 10.0.0.2
# below is the implicit "is the WG tunnel up?" gate.
link_is_metered() {                    # metered flag on the default-route iface
  command -v nmcli >/dev/null 2>&1 || return 1
  local dev; dev=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
  [[ -n "$dev" ]] || return 1
  nmcli -t -f GENERAL.METERED device show "$dev" 2>/dev/null | grep -qi ':yes'
}

if (( ! FORCE )) && [[ "$SKIP_IF_METERED" == "true" ]] && link_is_metered; then
  log "On a metered connection; skipping (not a failure)."   # silent to the DMS
  stale_exit "metered connection"
fi

# ---- Backend reachable? (10.0.0.2 is routable only through WireGuard) ----
# The classic WireGuard failure is a tunnel that is "up" but dead: the peer's
# endpoint moved (dynamic DNS, new NAT mapping) and the kernel keeps talking to
# the old address forever. Bouncing the interface re-resolves and re-punches.
# Split-tunnel (AllowedIPs = 10.0.0.0/24) keeps the blast radius at zero.
backend_reachable() {
  [[ -n "${REST_HEALTH_URL:-}" ]] || return 0
  curl -sS -o /dev/null -m 8 "$REST_HEALTH_URL" 2>/dev/null
}

wg_bounce() {
  [[ -n "$WG_INTERFACE$WG_RESTART_CMD" ]] || return 1

  # ---- Guards that apply to BOTH paths, checked before either one runs ----
  # No default route means the host is simply offline: `wg-quick up` could not
  # resolve the endpoint anyway, and a failed up() after a successful down()
  # leaves the tunnel DOWN -- strictly worse than what we started with. A
  # custom WG_RESTART_CMD is no better placed to reach a DNS server than the
  # built-in path is, so it waits for a default route too.
  if ! ip route show default 2>/dev/null | grep -q .; then
    log "WG: no default route -- host is offline; leaving the tunnel alone."
    return 1
  fi
  # "Bounce once" has to mean once per OUTAGE, not once per run. While today's
  # backup has not succeeded every hourly invocation is due, so an endpoint
  # that is genuinely down for two days would otherwise meet 48 restarts. The
  # first bounce of an outage is still immediate -- only retries are spaced --
  # and a successful backup clears the record.
  local last since
  last=$(read_epoch "$WG_BOUNCE_FILE")
  since=$(( NOW - last ))
  if (( WG_BOUNCE_INTERVAL_SEC > 0 && last > 0 && since >= 0 \
        && since < WG_BOUNCE_INTERVAL_SEC )); then
    log "WG: already bounced $(fmt_age "$since") ago; waiting (WG_BOUNCE_INTERVAL_HOURS=$WG_BOUNCE_INTERVAL_HOURS)."
    return 1
  fi

  # The interval slot is spent by a bounce that RAN, not by one we merely
  # reached the decision to attempt. Recording it up front meant that the one
  # outcome needing another attempt soonest -- `down` succeeded, `up` failed,
  # tunnel now fully DOWN, as the log below says -- was also the one guaranteed
  # not to get one for WG_BOUNCE_INTERVAL_HOURS, even though re-running `up` is
  # the only thing that recovers it. A restart mechanism that is simply absent
  # never spends the slot either.
  #
  # So each path below records its own attempt on success. A mechanism that
  # fails every hour therefore retries every hour: noisier than the old
  # behaviour, but it is a broken restart command or a vanished interface,
  # logged every time, not the "endpoint down for two days" case the interval
  # exists for -- that one bounces cleanly and is still rate-limited.
  if [[ -n "$WG_RESTART_CMD" ]]; then
    log "WG: running WG_RESTART_CMD"
    if ! bash -c "$WG_RESTART_CMD" 9>&-; then log "WG: WG_RESTART_CMD failed."; return 1; fi
    write_state "$WG_BOUNCE_FILE" "$NOW"
    sleep "$WG_SETTLE_SECS"; return 0
  fi
  # Never run wg-quick behind systemd's back: it would leave the unit thinking
  # the interface is still up.
  if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet "wg-quick@$WG_INTERFACE"; then
    log "WG: restarting wg-quick@$WG_INTERFACE (systemd-managed)"
    if ! systemctl restart "wg-quick@$WG_INTERFACE" 9>&-; then log "WG: systemctl restart failed."; return 1; fi
  elif command -v wg-quick >/dev/null 2>&1; then
    log "WG: bouncing $WG_INTERFACE with wg-quick"
    wg-quick down "$WG_INTERFACE" 9>&- >/dev/null 2>&1 || true # may already be down
    if ! wg-quick up "$WG_INTERFACE" 9>&-; then
      log "WG: 'wg-quick up $WG_INTERFACE' FAILED -- the tunnel is now DOWN."
      return 1
    fi
  else
    log "WG: neither a wg-quick@$WG_INTERFACE unit nor a wg-quick binary; cannot restart."
    return 1
  fi
  write_state "$WG_BOUNCE_FILE" "$NOW"
  sleep "$WG_SETTLE_SECS"
  return 0
}

if ! backend_reachable; then
  log "Backend ${REST_HEALTH_URL:-} unreachable (WG down?)."
  if [[ -z "$WG_INTERFACE$WG_RESTART_CMD" ]]; then
    stale_exit "backend unreachable (WireGuard down?)"
  elif ! wg_bounce; then
    stale_exit "backend unreachable; WireGuard restart skipped or failed"
  elif ! backend_reachable; then
    stale_exit "backend still unreachable after restarting WireGuard"
  else
    log "Backend reachable again after restarting the tunnel."
  fi
fi

ping_dms "$PING_URL/start"

# ============================================================================
#  DUMP STAGE  --  native DB dumps into $DUMP_DIR (selected by the config arrays
#  above), then the optional pre-backup hook for anything the config cannot
#  express. The dir is added to the backup set and WIPED on exit so plaintext
#  never lingers. Any failure aborts the whole run (better no backup than a
#  half-dumped DB).
#
#  ORDER MATTERS: the hook runs AFTER the native dumps and writes into the same
#  directory, so the hook must never clear $DUMP_DIR itself -- see ./pre-backup.
# ============================================================================
PRE_BACKUP_HOOK="${PRE_BACKUP_HOOK:-$CONFIG_DIR/pre-backup}"   # optional generic hook
# find, not `rm -rf "$DUMP_DIR"/*`: a glob does not match leading dots, so a
# hook that wrote $DUMP_DIR/.env or a tool that left a dot-prefixed temp file
# left plaintext behind after a run that promised to wipe it.
cleanup_dumps() { find "${DUMP_DIR:?}" -mindepth 1 -delete 2>/dev/null || true; }
if _have_db_config || [[ -x "$PRE_BACKUP_HOOK" ]]; then
  # A symlinked $DUMP_DIR would send every plaintext dump through it and have
  # the chmod land on the target, so refuse one outright; -m 700 keeps the
  # directory from existing world-readable even for the instant between mkdir
  # and chmod (the chmod stays, for a directory that already exists).
  # preflight_fail, not a bare exit: this is as fatal as any config guard above,
  # and a bare `exit` here reaches nobody -- it does not fire the ERR trap, the
  # run never gets far enough to touch the last-backup stamp, and the host would
  # simply fail silently every hour until the dead-man's switch noticed.
  [[ ! -L "$DUMP_DIR" ]] || preflight_fail "\$DUMP_DIR ($DUMP_DIR) is a symlink"
  mkdir -p -m 700 "$DUMP_DIR"; chmod 700 "$DUMP_DIR"
  # EXIT alone is not enough: a non-interactive bash killed by an untrapped
  # SIGTERM -- a reboot, `systemctl stop`, the OOM killer -- dies without running
  # it, and a full pg_dumpall then sits in $DUMP_DIR in plaintext until the next
  # DUE run -- the coming midnight at the latest, and never at all if the
  # config broke in the meantime. Not a failure to page about; the staleness
  # alarm covers the missed backup.
  trap 'cleanup_dumps' EXIT
  trap 'log "Interrupted (SIGTERM); wiping $DUMP_DIR."; cleanup_dumps; exit 143' TERM
  trap 'log "Interrupted (SIGINT); wiping $DUMP_DIR.";  cleanup_dumps; exit 130' INT
  trap 'log "Interrupted (SIGHUP); wiping $DUMP_DIR.";  cleanup_dumps; exit 129' HUP
  cleanup_dumps                       # clear any junk a crashed run left
  # 077 covers the hook as well as the native dumps. The hook writes plaintext
  # into the same directory and is equally hand-written; restoring the
  # inherited umask first (022 under cron) meant a hook that does not set its
  # own -- the shipped ./pre-backup does, a copied-and-edited one may not --
  # produced world-readable dumps. DUMP_DIR being 0700 contains it either way,
  # but there is no reason to widen the mask for the one stage most likely to
  # get this wrong.
  __um=$(umask); umask 077            # dumps are 0600
  run_db_dumps
  [[ -x "$PRE_BACKUP_HOOK" ]] && {
    require_trusted "$PRE_BACKUP_HOOK" "the pre-backup hook"
    export DUMP_DIR; run_step "pre-backup-hook" "$PRE_BACKUP_HOOK"
  }
  umask "$__um"
  # Any artifact counts, not just *.sql -- the hook is generic and may write
  # anything, dot-prefixed included, which is why this is find and not a glob.
  # (A failing test here is exempt from set -e: it precedes the &&.)
  [[ -n "$(find "$DUMP_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]] \
    && BACKUP_PATHS+=("$DUMP_DIR")
fi

# ---- Self-heal stale locks in this client's subrepo (stale-only; safe) ----
run_step "unlock" restic unlock

# ---- Backup ----
run_step "backup" restic backup \
  --retry-lock "$LOCK_WAIT" \
  --exclude-caches \
  "${EXCLUDE_ARGS[@]}" \
  ${EXTRA_BACKUP_ARGS+"${EXTRA_BACKUP_ARGS[@]}"} \
  "${BACKUP_PATHS[@]}"

# No forget/prune/check here (append-only; retention lives on the maintenance host).

# ---- Record success ----
# .last-success is written ONLY here, and only after restic returned 0. Every
# scheduling and staleness decision reads it; a lock-skip or a failed run must
# never touch it, or a wedged host would look freshly backed up.
# `|| true` for the same reason write_state never fails: these run AFTER restic
# returned 0, and under set -e with the ERR trap armed a read-only / would turn
# a backup that worked into an urgent "Backup FAILED" push.
write_state "$LAST_SUCCESS_FILE" "$(date +%s)"
rm -f "$NOTIFY_STATE_FILE" || true    # failure streak is over; next failure pages again
rm -f "$WG_BOUNCE_FILE"    || true    # tunnel is fine; the next outage may bounce at once

log "Backup complete."
ping_dms "$PING_URL"

# Advisory only, and last on purpose: the backup is already done and reported,
# so nothing here can affect it.
version_check
