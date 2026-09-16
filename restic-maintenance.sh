#!/bin/bash
set -euo pipefail

# ============================================================================
# restic MAINTENANCE run -- forget / prune / check / restore-test for every
# client repo, against the rest-maintenance-server (LAN-only, delete-capable).
#
# This is the ONLY place forget/prune run. Client backup scripts push to the
# append-only rest-server and never touch retention.
#
# Order per client: unlock -> forget -> prune -> check -> restore-test.
#                    check and restore-test run EVERY run; forget and prune
#                    only when this client's last successful prune is
#                    PRUNE_MIN_INTERVAL_DAYS old, give or take the half-day of
#                    slack at PRUNE_DUE_SLACK (or --prune).
#
#                    check runs AFTER prune deliberately: prune is the one step
#                    that rewrites pack files, so verifying behind it is what
#                    catches a bad repack, in the run that caused it.
#
# Why per-client instead of one shared schedule day: prune is the expensive
# step (repacking touches every partially-used pack file), so pruning every
# client on the same calendar day piles all of that onto one window. Instead
# each client tracks its own "last successful prune" timestamp in
# $CONFIG_DIR/state/last-prune-<name> (written by this script) and becomes
# due independently once that ages past the interval. A client seen for the
# first time (no state file yet) gets a deterministic offset derived from its
# name, so new clients spread across the week from day one instead of all
# pruning together on their first run.
#
# forget itself recomputes the full keep-set from the current snapshot list
# every time it runs -- it has no memory of prior runs -- so it's gated
# together with prune rather than run more often: running it daily wouldn't
# change the retention outcome, only add churn, since space isn't reclaimed
# until prune runs anyway. check/restore-test stay on the daily cadence
# regardless, since they're read-only integrity signals you want promptly,
# independent of retention housekeeping.
#
# Usage:
#   ./restic-maintenance.sh            # normal run: forget/prune only for
#                                       # clients whose last prune is overdue
#   ./restic-maintenance.sh --prune    # force forget/prune for EVERY client
#                                       # this run (resets their stagger),
#                                       # e.g. after changing a retention
#                                       # policy and wanting space back sooner
#
# Auth: each client keeps its own username (matching --private-repos), but the
# password used here is the SEPARATE maintenance-only password (distinct
# htpasswd file on rest-maintenance-server) -- a leaked client backup
# credential cannot authenticate against this port/file.
#
# Requires restic >= client's version (see client script header).
# ============================================================================

export PATH="/usr/local/bin:/usr/bin:/bin:${PATH:-}"
export GOGC=20

# ---- CLI args ----
FORCE_PRUNE=false
for arg in "$@"; do
  case "$arg" in
    --prune) FORCE_PRUNE=true ;;
    *) echo "FATAL: unknown argument '$arg' (only --prune is supported)" >&2; exit 1 ;;
  esac
done

# ---- Trusted paths -------------------------------------------------------
# This host decrypts every client's repository, which makes it the most
# sensitive machine in the design. `source config` EXECUTES that file, and the
# same file carries MAINT_PASSWORD and the ntfy token -- so anything that can
# write it, or write a directory on the way to it, owns this host and every
# repo it reaches. Existence is not a sufficient check. Same rule the client
# script applies to its own config, for the same reason.
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

# Fatal, and by hand rather than through log()/ntfy(): this runs BEFORE the
# config that defines where notifications go.
require_trusted() {                    # require_trusted PATH DESCRIPTION
  local p="$1" desc="$2" d
  path_is_trusted "$p" || {
    echo "FATAL: $desc ($p) must be owned by root or UID $EUID and not group/world-writable." >&2
    echo "  It is read as UID $EUID on a host that can decrypt every client repo." >&2
    exit 1; }
  d="$(dirname "$(readlink -f "$p")")"
  while :; do
    path_is_trusted "$d" || { echo "FATAL: $desc ($p) sits under a directory anyone can write ($d)" >&2; exit 1; }
    [[ "$d" == / ]] && break
    d="$(dirname "$d")"
  done
}

# ---- Load global config ----
CONFIG_DIR="${RESTIC_MAINT_CONFIG_DIR:-$HOME/.config/restic-maintenance}"
[[ -f "$CONFIG_DIR/config" ]] || { echo "FATAL: missing $CONFIG_DIR/config" >&2; exit 1; }
require_trusted "$CONFIG_DIR/config" "the maintenance config"
# shellcheck disable=SC1091
source "$CONFIG_DIR/config"
#
# See maintenance.config.sample for the full, documented set. Summary:
#   REST_MAINT_URL, MAINT_PASSWORD, CLIENTS, FORGET_POLICY_DEFAULT   REQUIRED
#   LOCK_WAIT, RESTORE_TEST_ROOT, RESTORE_TEST_PATH, CHECK_READ_DATA_SUBSET,
#   PRUNE_MIN_INTERVAL_DAYS, REST_HEALTH_URL, NTFY_*, RESTIC_PING_URL  optional
#   FORGET_POLICY_BY_CLIENT[name], RESTORE_TEST_PATH_BY_CLIENT[name]  optional
#     per-client overrides, both associative arrays, defined right in config.
#
# The ONE thing that stays outside this file, per client:
#   $CONFIG_DIR/encryption_pw_<name>   REQUIRED -- restic encryption password
#   for that client's repo. Kept out of config because it's a secret, not a
#   setting -- everything else lives in config.

declare -p CLIENTS &>/dev/null || { echo "FATAL: CLIENTS not set in config" >&2; exit 1; }
(( ${#CLIENTS[@]} )) || { echo "FATAL: CLIENTS is empty" >&2; exit 1; }
declare -p FORGET_POLICY_DEFAULT &>/dev/null || { echo "FATAL: FORGET_POLICY_DEFAULT not set" >&2; exit 1; }
# It is expanded as "${FORGET_POLICY_DEFAULT[@]}" below, so a plain string
# collapses into ONE restic argument -- "--keep-daily 7 --keep-weekly 4" as a
# single flag -- and restic rejects it with a message about neither. Note the
# asymmetry this guards: the DEFAULT is an array, while a per-client override
# in FORGET_POLICY_BY_CLIENT is a space-separated STRING, because bash cannot
# nest an array inside an associative array.
[[ "$(declare -p FORGET_POLICY_DEFAULT)" == "declare -a"* ]] || {
  echo "FATAL: FORGET_POLICY_DEFAULT must be a bash ARRAY, e.g." >&2
  echo "  FORGET_POLICY_DEFAULT=(--keep-daily 7 --keep-weekly 4)" >&2
  exit 1; }
[[ -n "${REST_MAINT_URL:-}" ]] || { echo "FATAL: REST_MAINT_URL not set" >&2; exit 1; }
[[ -n "${MAINT_PASSWORD:-}" ]] || { echo "FATAL: MAINT_PASSWORD not set" >&2; exit 1; }

# Optional associative-array overrides -- declare empty ones if config didn't
# define them, so later lookups (`${ARR[$client]:-}`) never hit an unbound
# variable under `set -u`.
declare -p FORGET_POLICY_BY_CLIENT &>/dev/null || declare -A FORGET_POLICY_BY_CLIENT=()
declare -p RESTORE_TEST_PATH_BY_CLIENT &>/dev/null || declare -A RESTORE_TEST_PATH_BY_CLIENT=()

LOCK_WAIT="${LOCK_WAIT:-15m}"
RESTORE_TEST_ROOT="${RESTORE_TEST_ROOT:-/tmp/restic-restore-test}"
RESTORE_TEST_ROOT="${RESTORE_TEST_ROOT%/}"           # config may end in a slash
RESTORE_TEST_PATH_DEFAULT="${RESTORE_TEST_PATH:-/etc/hostname}"
CHECK_READ_DATA_SUBSET="${CHECK_READ_DATA_SUBSET:-}"
PRUNE_MIN_INTERVAL_DAYS="${PRUNE_MIN_INTERVAL_DAYS:-7}"   # prune when last prune >= this many days ago
# client_prune_offset_days takes this modulo, so a 0 here is a division by zero
# that kills the whole run on the first client. 1 means "whenever this cron
# fires", which is the closest thing to "every run".
[[ "$PRUNE_MIN_INTERVAL_DAYS" =~ ^[0-9]+$ ]] && (( PRUNE_MIN_INTERVAL_DAYS >= 1 )) || {
  echo "FATAL: PRUNE_MIN_INTERVAL_DAYS must be a whole number >= 1 (got '$PRUNE_MIN_INTERVAL_DAYS')" >&2; exit 1; }

# The interval is counted in seconds, but the run that spends it is daily and
# reaches each client at a different moment every day: the clients ahead of it
# in CLIENTS take a different amount of time to check, and check dominates the
# runtime. Comparing against a flat N*86400 therefore defers a client that is
# reached a few SECONDS earlier in the day than the run that stamped it -- the
# gap reads as N-1 days and it waits a whole extra day for a schedule that only
# offers one decision per day. Half a day of slack absorbs the jitter: due
# lands mid-night, every run of the day sees it, and the cadence holds at
# exactly N days while the run's start time moves by less than 12h. Beyond
# that (a NAS outage delaying a run past midnight) one cycle stretches to N+1
# days and re-anchors, which is the safe direction for an expensive step.
PRUNE_DUE_SLACK=43200

NTFY_URL="${NTFY_URL:-}"
NTFY_TOPIC_HIGH="${NTFY_TOPIC_HIGH:-backups-high}"
NTFY_TOKEN="${NTFY_TOKEN:-}"
PING_URL="${RESTIC_PING_URL:-}"

STATE_DIR="$CONFIG_DIR/state"
mkdir -p "$STATE_DIR"

# client_prune_offset_days CLIENT -- deterministic 0..(interval-1) offset
# derived from the client's name, used only to seed a staggered starting
# point for clients that have never been pruned yet (no state file). This is
# what spreads first-time clients across the week instead of all becoming
# due on the same day.
client_prune_offset_days() {
  local client="$1"
  local hash; hash="$(cksum <<< "$client" | cut -d' ' -f1)"
  printf '%s' "$(( hash % PRUNE_MIN_INTERVAL_DAYS ))"
}

# ---- Helpers (same conventions as the client script) ----
log() { printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*"; }
# seconds -> "6d21h". Days alone cannot show the prune gate's real margin: a
# client an hour short of due and one a day short both print "6d".
# A stamp in the future (clock jump, hand-edited state) would otherwise print a
# negative hour count; the gate itself just skips until real time catches up.
fmt_age_dh() { local s="$1"; (( s < 0 )) && s=0; printf '%dd%02dh' $(( s / 86400 )) $(( (s % 86400) / 3600 )); }
ping_dms() { [[ -n "$PING_URL" ]] || return 0; curl -fsS -m 10 --retry 3 "$1" >/dev/null 2>&1 || true; }

# Atomic, and deliberately never fatal: a state write that fails must not turn
# a prune that worked into a failed run. The cost of losing it is one extra
# prune next time, which is the safe direction.
write_state() {                        # write_state FILE VALUE
  local f="$1" tmp
  tmp="$(mktemp "$(dirname "$f")/.$(basename "$f").XXXXXX" 2>/dev/null)" || {
    log "WARN: could not create a temp file beside $f (state not recorded)"; return 0; }
  if printf '%s' "$2" > "$tmp" 2>/dev/null && mv -f "$tmp" "$f" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null || true
  log "WARN: could not write $f (state not recorded)"
  return 0
}

# The restore test materialises a real directory per client. An abort between
# the mkdir and the cleanup leaves it behind, and RESTORE_TEST_ROOT defaults
# under /tmp -- which on a Pi is often tmpfs, so the leak is RAM. Hanging the
# removal off EXIT as well as the normal path covers set -e, a failed step and
# Ctrl-C alike.
RESTORE_DIR=""
cleanup_restore() {
  if [[ -n "$RESTORE_DIR" ]]; then
    rm -rf "$RESTORE_DIR" 2>/dev/null || true
    RESTORE_DIR=""
  fi
  return 0
}
trap cleanup_restore EXIT

ntfy() {
  local topic="$1" priority="$2" tags="$3" title="$4" body="$5"
  local args=(-H "Title: $title" -H "Priority: $priority" -H "Tags: $tags")
  [[ -n "$NTFY_TOKEN" ]] && args+=(-H "Authorization: Bearer $NTFY_TOKEN")
  curl -fsS -m 15 --retry 3 "${args[@]}" --data-binary "$body" \
    "$NTFY_URL/$topic" >/dev/null 2>&1 || log "WARN: ntfy send failed"
}

notify_failure() {
  local client="$1" stage="$2" code="$3" output="$4"
  ntfy "$NTFY_TOPIC_HIGH" urgent rotating_light \
    "Maintenance FAILED: $client ($stage)" \
"Client: $client
Stage:  $stage
Exit:   $code
$(printf '%s' "$output" | tail -c 1500)"
}

# run_step CLIENT STAGE cmd...  -- logs, captures output, notifies on failure,
# but returns the exit code instead of killing the whole script (one client's
# failure must not stop maintenance on the others).
run_step() {
  local client="$1" stage="$2"; shift 2
  log "[$client] >>> $stage"
  set +e
  local out; out="$("$@" 2>&1)"; local rc=$?
  set -e
  printf '%s\n' "$out"
  if (( rc != 0 )); then
    log "[$client] ERROR during '$stage' (exit $rc)"
    notify_failure "$client" "$stage" "$rc" "$out"
  fi
  return $rc
}

# ---- Single-instance lock ----
mkdir -p "$CONFIG_DIR"
# Not optional. Without it two runs overlap, and while restic's own repo lock
# keeps that from corrupting anything, the second run fights the first for
# LOCK_WAIT and then reports failures that are pure self-collision. Silently
# skipping the lock because a binary is absent hides that completely.
command -v flock >/dev/null 2>&1 || {
  log "FATAL: flock is not installed; refusing to run without single-instance protection."
  exit 1; }
exec 9>"$CONFIG_DIR/.lock"
flock -n 9 || { log "Another maintenance run holds the lock; exiting."; exit 0; }

# ---- Backend reachable? ----
if [[ -n "${REST_HEALTH_URL:-}" ]] && ! curl -sS -o /dev/null -m 8 "$REST_HEALTH_URL"; then
  log "Maintenance backend $REST_HEALTH_URL unreachable."
  ntfy "$NTFY_TOPIC_HIGH" urgent rotating_light "Maintenance run aborted" \
    "Could not reach $REST_HEALTH_URL"
  exit 1
fi

ping_dms "$PING_URL/start"

# ---- read-data verification subset --------------------------------------
# Rotate a deterministic slice of the repo through `check --read-data` so the
# whole repo is verified over several runs without paying the bandwidth of a
# full read-data every time.
#
# CHECK_READ_DATA_SUBSET is an integer percent, e.g. "10%". It is turned into
# restic's `n/t` form: the repo's pack files are split into t = 100/pct groups
# and group n is checked, with n advancing by one each day (mod t). That covers
# the entire repo roughly every t runs. The `x%` form is deliberately NOT used
# because it re-samples at random each run and never guarantees full coverage.
#
# `10#` forces base-10 so day-of-year values 008/009 are not misread as octal.
read_data_subset_arg() {
  [[ -n "$CHECK_READ_DATA_SUBSET" ]] || return 0
  local pct="${CHECK_READ_DATA_SUBSET%\%}"
  [[ "$pct" =~ ^[0-9]+$ ]] || {
    log "WARN: CHECK_READ_DATA_SUBSET='$CHECK_READ_DATA_SUBSET' is not an integer percent; running check without --read-data"
    return 0
  }
  (( pct > 0 && pct <= 100 )) || return 0
  local slots=$(( 100 / pct ))       # 10% -> 10 groups; 100% -> 1 (whole repo)
  (( slots < 1 )) && slots=1
  local slot=$(( 10#$(date +%j) % slots + 1 ))   # 1..slots
  printf -- '--read-data-subset=%s/%s' "$slot" "$slots"
}

overall_rc=0

for client in "${CLIENTS[@]}"; do
  pw_file="$CONFIG_DIR/encryption_pw_$client"

  if [[ ! -f "$pw_file" ]]; then
    log "[$client] FATAL: missing $pw_file, skipping this client."
    notify_failure "$client" "config" 1 "Missing repo-password file at $pw_file"
    overall_rc=1
    continue
  fi

  # Per-client restore-test sentinel, else the global default.
  RESTORE_TEST_PATH="${RESTORE_TEST_PATH_BY_CLIENT[$client]:-$RESTORE_TEST_PATH_DEFAULT}"

  export RESTIC_REPOSITORY="rest:${REST_MAINT_URL}/${client}/"
  export RESTIC_REST_USERNAME="$client"
  export RESTIC_REST_PASSWORD="$MAINT_PASSWORD"
  export RESTIC_PASSWORD_FILE="$pw_file"

  client_rc=0

  # Stale-lock cleanup only (no removal of live locks): must not disturb a live
  # client backup. Runs from this (maintenance) host, so client locks can only
  # be reaped by the age rule, and healthy client backups refresh their lock
  # well within that window.
  run_step "$client" "unlock" restic unlock || client_rc=1

  # Is this client's prune overdue? First time seen (no state file): seed a
  # deterministic offset from its name so it doesn't become due on the same
  # day as every other first-time client -- see client_prune_offset_days().
  state_file="$STATE_DIR/last-prune-$client"
  now_epoch="$(date +%s)"
  last_prune_epoch=""
  if [[ -f "$state_file" ]]; then
    last_prune_epoch="$(cat "$state_file" 2>/dev/null || true)"
    # A truncated or hand-edited file would otherwise reach the arithmetic
    # below, where a non-numeric value silently evaluates to 0 (age: 57 years,
    # prune every run) and something like "1)" is a syntax error that kills the
    # run under set -e.
    [[ "$last_prune_epoch" =~ ^[0-9]+$ ]] || {
      log "[$client] WARN: $state_file does not hold a timestamp; reseeding it."
      last_prune_epoch=""
    }
  fi
  if [[ -z "$last_prune_epoch" ]]; then
    # Seed the clock ONCE, and WRITE IT DOWN.
    #
    # Recomputing this from $now_epoch on every run makes the age below a
    # CONSTANT -- exactly PRUNE_MIN_INTERVAL_DAYS minus the offset -- because
    # both sides move together. Every client whose offset is not precisely 0
    # then sits one step short of the threshold forever, logging "skipped"
    # every day and never pruning, while the state file that would release it
    # is only written after a prune that never happens. Anchored to a fixed
    # point, the age grows and the stagger works as intended.
    #
    # Until the first real prune overwrites it, this file records where the
    # clock STARTED, not a prune that took place.
    offset_days="$(client_prune_offset_days "$client")"
    last_prune_epoch=$(( now_epoch - (PRUNE_MIN_INTERVAL_DAYS - offset_days) * 86400 ))
    write_state "$state_file" "$last_prune_epoch"
  fi
  age_seconds=$(( now_epoch - last_prune_epoch ))
  due_epoch=$(( last_prune_epoch + PRUNE_MIN_INTERVAL_DAYS * 86400 - PRUNE_DUE_SLACK ))

  if [[ "$FORCE_PRUNE" == "true" ]] || (( now_epoch >= due_epoch )); then
    run_prune_this_client=true
    log "[$client] forget/prune: due (last prune $(fmt_age_dh "$age_seconds") ago, every ${PRUNE_MIN_INTERVAL_DAYS}d$([[ "$FORCE_PRUNE" == "true" ]] && echo ", --prune forced"))"
  else
    run_prune_this_client=false
    log "[$client] forget/prune: skipped (last prune $(fmt_age_dh "$age_seconds") ago, due $(date -d "@$due_epoch" '+%Y-%m-%dT%H:%M'))"
  fi

  if [[ "$run_prune_this_client" == "true" ]]; then
    # Per-client forget policy override, else the global default. Overrides
    # are stored as a single space-separated string in config (bash
    # associative arrays can't hold nested arrays), split back into an array
    # here.
    if [[ -n "${FORGET_POLICY_BY_CLIENT[$client]:-}" ]]; then
      read -ra FORGET_POLICY <<< "${FORGET_POLICY_BY_CLIENT[$client]}"
    else
      FORGET_POLICY=("${FORGET_POLICY_DEFAULT[@]}")
    fi

    # --group-by belongs HERE and not in the policy. restic's default is
    # host,paths, which applies the keep-set separately to every distinct PATH
    # SET -- and a client's path set moves: adding /boot to its BACKUP_PATHS
    # changes it, and so does a night where the dumps produce nothing, since
    # the client appends $DUMP_DIR only when that directory has content. Each
    # variant becomes its own group, and a group that stops receiving snapshots
    # never ages out, because --keep-daily 7 keeps the last 7 days THAT HAVE
    # snapshots, not the last 7 days. The orphan is thinned once and then
    # pinned forever, where prune cannot reclaim it.
    #
    # --private-repos gives one client per repo, so grouping by host is one
    # group per repo, which is the intent everywhere here. It sits before
    # "${FORGET_POLICY[@]}" so a per-client override can still replace it
    # deliberately -- pflag takes the last occurrence of a flag.
    run_step "$client" "forget" restic forget \
      --retry-lock "$LOCK_WAIT" --group-by host "${FORGET_POLICY[@]}" || client_rc=1

    # Only stamp "last prune" on actual success -- a failed prune should stay
    # overdue so the next run retries it, not silently wait another interval.
    if run_step "$client" "prune" restic prune --retry-lock "$LOCK_WAIT"; then
      write_state "$state_file" "$now_epoch"
    else
      client_rc=1
    fi
  fi

  subset_arg="$(read_data_subset_arg)"
  if [[ -n "$subset_arg" ]]; then
    run_step "$client" "check (with $subset_arg)" restic check \
      --retry-lock "$LOCK_WAIT" "$subset_arg" || client_rc=1
  else
    run_step "$client" "check" restic check \
      --retry-lock "$LOCK_WAIT" || client_rc=1
  fi

  # ---- Restore smoke test: pull ONE small known file out of the latest
  # snapshot. This proves the repo + encryption password + decrypt + restore
  # path still turn into real bytes -- something `check` alone does not verify --
  # without dragging the whole snapshot across the LAN. `latest` is
  # unambiguously this client's newest backup: private-repos gives one client
  # per repo. ----
  RESTORE_DIR="$RESTORE_TEST_ROOT/$client-$(date +%s)"
  mkdir -p "$RESTORE_DIR"
  if run_step "$client" "restore-test" restic restore latest \
       --target "$RESTORE_DIR" --include "$RESTORE_TEST_PATH" \
       --retry-lock "$LOCK_WAIT"; then
    # An --include that matches nothing still exits 0, so assert the file
    # actually materialised rather than trusting the exit code. restic recreates
    # the absolute path under --target, hence "$RESTORE_DIR$RESTORE_TEST_PATH".
    if [[ ! -s "$RESTORE_DIR$RESTORE_TEST_PATH" ]]; then
      log "[$client] ERROR: restore-test did not produce $RESTORE_TEST_PATH"
      notify_failure "$client" "restore-test" 1 \
        "restore latest --include $RESTORE_TEST_PATH exited 0 but $RESTORE_DIR$RESTORE_TEST_PATH is missing/empty"
      client_rc=1
    fi
  else
    client_rc=1
  fi
  cleanup_restore

  if (( client_rc != 0 )); then
    overall_rc=1
    log "[$client] maintenance finished WITH ERRORS"
  else
    log "[$client] maintenance finished OK"
  fi

  unset RESTIC_REPOSITORY RESTIC_REST_USERNAME RESTIC_REST_PASSWORD RESTIC_PASSWORD_FILE
done

if (( overall_rc == 0 )); then
  log "All clients: maintenance complete."
  ping_dms "$PING_URL"
else
  log "One or more clients failed maintenance -- see notifications above."
  ping_dms "$PING_URL/fail"
fi

exit "$overall_rc"
