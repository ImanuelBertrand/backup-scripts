#!/bin/bash
set -euo pipefail

# ============================================================================
# deploy.sh -- push the client files to every host in deploy.conf.
#
# PUSH, NOT PULL. restic-backup.sh runs as root on every host, so it must never
# fetch and execute code on its own: one compromised GitHub credential would
# otherwise be fleet-wide root, and with the hourly schedule it would land
# within the hour. Updates come from here instead -- from a machine a human is
# sitting at, with a diff shown before anything is written.
#
# What it deploys:   restic-backup.sh, excludes, and (per host, with that host's
#                    own minute) the /etc/cron.d entry.
#                    `excludes` is the FLEET-WIDE base and is overwritten in
#                    place, so a hand-edit on a target is reverted by the next
#                    deploy -- silently, the symptom being a snapshot that
#                    quietly stopped containing something.
# What it NEVER touches:
#                    config and encryption-pw  -- secrets, per host, hand-managed
#                    pre-backup                -- per-host hook, hand-managed
#                    excludes.local            -- this host's own patterns, read
#                                                 after `excludes` so it can add
#                                                 to it or take a pattern back
#
# How it connects:   ssh as $SSH_USER (deploy.conf), then runs every remote
#                    command that needs root through $SUDO -- default "sudo -n",
#                    which must be passwordless: BatchMode ssh cannot answer a
#                    password prompt. Where root logs in directly, set
#                    SSH_USER="root" and the sudo prefix drops out on its own.
#
#   ./deploy.sh                 plan, show diffs, ask, then apply
#   ./deploy.sh --check         report each host's --status; alerts nobody
#   ./deploy.sh --dry-run       plan and diff only
#   DIFF_LINES=0 ./deploy.sh    show every diff line (default: first 60 per file)
#   NO_COLOR=1 ./deploy.sh      plain diffs (colour is on only for a terminal)
#   ./deploy.sh --host srv01    just that host (repeatable)
#   ./deploy.sh --yes           skip the confirmation prompt; required when
#                               stdin is not a terminal (cron, CI)
#   ./deploy.sh --force         push even where the checksums already match,
#                               to undo a hand-edit made on a target
#   ALLOW_STALE=1 ./deploy.sh   push even though this checkout is behind its
#                               git remote (normally a refusal)
# ============================================================================

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${DEPLOY_CONF:-$SRC_DIR/deploy.conf}"

CHECK_ONLY=0; DRY_RUN=0; ASSUME_YES=0; FORCE=0
declare -a ONLY_HOSTS=()
# Prints the header block between the two banner lines, so adding a line to it
# cannot silently fall outside a hardcoded range (--yes and --force did).
usage() { sed -n '5,${/^# ==/q;s/^# \{0,1\}//;p;}' "${BASH_SOURCE[0]}"; }
while (( $# )); do
  case "$1" in
    -c|--check)   CHECK_ONLY=1 ;;
    -n|--dry-run) DRY_RUN=1 ;;
    -y|--yes)     ASSUME_YES=1 ;;
    -f|--force)   FORCE=1 ;;
    --host)       shift; [[ $# -gt 0 ]] || { echo "--host needs a value" >&2; exit 2; }; ONLY_HOSTS+=("$1") ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

# ---- config ----
[[ -f "$CONF" ]] || { echo "FATAL: no $CONF (copy deploy.conf.sample and edit it)" >&2; exit 1; }
declare -A CRON_MINUTE=()
SSH_USER="root"
SUDO="sudo -n"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10)
SBIN_PATH="/usr/local/sbin/restic-backup.sh"
CONFIG_DIR="/root/.config/restic"
CRON_PATH="/etc/cron.d/restic-backup"
# shellcheck disable=SC1090
source "$CONF"
declare -p HOSTS &>/dev/null || { echo "FATAL: HOSTS not set in $CONF" >&2; exit 1; }
(( ${#HOSTS[@]} )) || { echo "FATAL: HOSTS is empty in $CONF" >&2; exit 1; }

if (( ${#ONLY_HOSTS[@]} )); then
  declare -a sel=()
  for want in "${ONLY_HOSTS[@]}"; do
    found=0
    for h in "${HOSTS[@]}"; do [[ "$h" == "$want" ]] && { sel+=("$h"); found=1; }; done
    (( found )) || { echo "FATAL: '$want' is not in HOSTS" >&2; exit 1; }
  done
  HOSTS=("${sel[@]}")
fi

# A host listed in HOSTS but missing from CRON_MINUTE gets the script and no
# schedule. It then never backs up -- and the staleness alerting that would
# normally catch that only ever runs FROM cron, so nothing on that host or
# here will say a word. Its --status even reads "no successful backup on
# record", which is exactly what a healthy fresh install prints. Pure config,
# so it costs no ssh and is checked before anything is pushed.
declare -a NO_CRON=()
for h in "${HOSTS[@]}"; do [[ -n "${CRON_MINUTE[$h]:-}" ]] || NO_CRON+=("$h"); done
warn_no_cron() {
  (( ${#NO_CRON[@]} )) || return 0
  printf '\nWARNING: no CRON_MINUTE in %s for: %s\n' "$CONF" "${NO_CRON[*]}" >&2
  printf '  These hosts get the script but no schedule, so they will never back\n' >&2
  printf '  up and nothing will alert about it. Add a minute for each in %s.\n' "$CONF" >&2
}

# Same class of problem as a missing CRON_MINUTE: the deploy succeeds, --status
# looks like a fresh install, and the host never backs up. Reported, not
# enforced during a deploy -- a first deploy legitimately lands before the
# hand-managed config. --check is not a deploy, so there it is a failure.
declare -A PREREQ=()
warn_prereqs() {
  (( ${#PREREQ[@]} )) || return 0
  printf '\nWARNING: missing prerequisites on:\n' >&2
  local k
  for k in "${!PREREQ[@]}"; do printf '  %-20s %s\n' "$k" "${PREREQ[$k]}" >&2; done
  printf '  Each of these installs cleanly and then backs nothing up.\n' >&2
}

# Both of these produce a host with NO schedule, which is the one failure state
# neither this tool nor the host itself can report afterwards -- the staleness
# alerting only ever runs from the cron job that is missing.
#
# cron.d files are parsed whole: a single malformed line makes cronie reject the
# entire file. render_cron splices the minute in with `awk -v`, which also
# interprets backslash escapes, so an unvalidated value can inject a line as
# easily as break one. And a filename containing a dot is silently ignored --
# restic-backup.cron documents that, and nothing enforced it.
for h in "${HOSTS[@]}"; do
  m="${CRON_MINUTE[$h]:-}"
  [[ -z "$m" ]] && continue
  if ! [[ "$m" =~ ^[0-9]{1,2}$ ]] || (( 10#$m > 59 )); then
    echo "FATAL: CRON_MINUTE[$h]='$m' in $CONF must be a whole number 0-59." >&2
    echo "  Anything else makes cronie reject the whole file, and the host then" >&2
    echo "  has no schedule at all -- with nothing to report that it hasn't." >&2
    exit 1
  fi
done
if [[ "$(dirname "$CRON_PATH")" == /etc/cron.d && "$(basename "$CRON_PATH")" == *.* ]]; then
  echo "FATAL: CRON_PATH ($CRON_PATH) has a dot in its filename." >&2
  echo "  cronie silently ignores /etc/cron.d entries whose names contain one, so" >&2
  echo "  the file would deploy successfully and never run." >&2
  exit 1
fi

addr_of() { [[ "$1" == *@* ]] && printf '%s' "$1" || printf '%s@%s' "$SSH_USER" "$1"; }
sha_of()  { sha256sum "$1" | awk '{print $1}'; }

# The prefix for every remote command, with its trailing space: $SUDO unless the
# login is already root. EVERY path this tool touches is root-only -- it writes
# /usr/local/sbin and /etc/cron.d, and it reads, hashes and diffs $CONFIG_DIR
# under /root -- so this is not confined to the pushes. Left off the reads, the
# hashes come back empty, every file looks changed, and the run re-pushes the
# whole fleet on every invocation before failing on the first write.
sudo_for() {                           # sudo_for <user@host>
  [[ "${1%%@*}" == root ]] && return 0
  printf '%s ' "$SUDO"
}

# Single-quote a value for the remote shell. Everything here crosses an ssh
# command line, which means it is expanded TWICE -- once locally, once by the
# remote shell -- and the paths come from deploy.conf, which is sourced as bash
# and so is full-trust local input. This is not a privilege boundary; it is what
# keeps a path containing a quote or a space from silently building a different
# command on the far side.
rq() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

# Pick one path's hash out of a `sha256sum a b c` run.
#
# NOT `awk '$2==p'`: sha256sum separates the hash from the name with TWO spaces
# and does not escape a space INSIDE the name, so for /opt/a b/f.sh the second
# field is "/opt/a" and the match never fires. The hash then came back empty,
# compared unequal to the local one, and the host was reported as needing that
# file on every single run and re-pushed forever. rq() was added so these paths
# survive the ssh boundary; this is the other half of that.
#
# Match on the fixed-width hash and on the exact remainder of the line instead.
# A name containing a backslash makes sha256sum escape the line and prefix it
# with '\', so that marker is stripped and '\\' undone first. (A name with a
# newline in it cannot be recognised line-wise at all, and cannot be a script
# or cron path here.) Written without regex intervals, which mawk and busybox
# awk have not always supported.
remote_sha() {                         # remote_sha <sha256sum-output> <path>
  awk -v p="$2" '
    /^\\/ { sub(/^\\/, ""); gsub(/\\\\/, "\\") }
    length($0) > 66 &&
    (substr($0, 65, 2) == "  " || substr($0, 65, 2) == " *") &&
    substr($0, 1, 64) ~ /^[0-9a-f]+$/ &&
    substr($0, 67) == p { print substr($0, 1, 64) }
  ' <<<"$1"
}

# The shell fragment that reports what a host is missing, emitted as '#PRE '
# lines. Shared by --check and the plan pass so the two modes cannot disagree
# about what a healthy host needs -- none of these can be seen from here, and
# every one of them is a host that installs cleanly and then never backs up.
#
# Collapse its output into one line. awk, not `paste -sd, - | sed 's/,/, /g'`:
# that sed spaced out every comma, including the ones inside a message, so a
# probe line with internal punctuation rendered "(health check,  ntfy,  dead-
# mans switch)". Joining at the real boundaries is what was meant.
prereq_list() {                        # prereq_list <probe output>
  awk '/^#PRE /{ sub(/^#PRE /, ""); out = (out ? out ", " : "") $0 } END { print out }' <<<"$1"
}

# Probed AS ROOT, via $1 (the sudo_for prefix). The question is never what the
# login user can see -- it is whether the hourly root cron job will work, and the
# two files live under /root, where an unprivileged probe reports "no config" on
# a perfectly healthy host. PATH differs between the two users as well, so the
# command lookups go through root's shell too.
prereq_probe() {                       # prereq_probe <sudo-prefix>
  local S="$1"
  cat <<EOF
${S}sh -c 'command -v restic >/dev/null 2>&1' || echo '#PRE restic is not installed'
${S}sh -c 'command -v flock  >/dev/null 2>&1' || echo '#PRE flock is missing (util-linux)'
${S}sh -c 'command -v curl   >/dev/null 2>&1' || echo '#PRE curl is missing (health check, ntfy, dead-mans switch)'
${S}test -f $(rq "$CONFIG_DIR/config")        || echo '#PRE no config'
${S}test -r $(rq "$CONFIG_DIR/encryption-pw") || echo '#PRE no encryption-pw'
EOF
}

# Rewrite the shipped cron template for ONE host: its own minute, and whatever
# paths deploy.conf uses.
render_cron() {
  awk -v m="$1" -v sbin="$SBIN_PATH" -v cfg="$CONFIG_DIR" '
    /^RESTIC_CONFIG_DIR=/ { print "RESTIC_CONFIG_DIR=" cfg; next }
    $0 ~ /restic-backup\.sh/ && $0 !~ /^[[:space:]]*#/ { sub(/^[[:space:]]*[^[:space:]]+/, "  " m) }
    { gsub("/usr/local/sbin/restic-backup.sh", sbin); print }
  ' "$SRC_DIR/restic-backup.cron"
}

# ---- check mode: report only ----
if (( CHECK_ONLY )); then
  rc=0
  for h in "${HOSTS[@]}"; do
    printf '\n=== %s ===\n' "$h"
    # The prerequisite probe used to live only in the plan pass, which --check
    # returns before ever reaching -- so the mode documented as the CI gate
    # never once reported a missing restic or flock. A host with restic
    # uninstalled passed cleanly (--status does not call check_restic_present
    # either) right up until MAX_BACKUP_AGE_HOURS elapsed, hours later.
    #
    # Same round trip, and --status runs LAST so $? is still its own exit code.
    S="$(sudo_for "$(addr_of "$h")")"
    out=$(ssh -n "${SSH_OPTS[@]}" "$(addr_of "$h")" "$(prereq_probe "$S")
         ${S}env RESTIC_CONFIG_DIR=$(rq "$CONFIG_DIR") $(rq "$SBIN_PATH") --status" 2>&1) && s=0 || s=$?
    prereq="$(prereq_list "$out")"
    [[ -n "$prereq" ]] && PREREQ[$h]="$prereq"
    sed '/^#PRE /d' <<<"$out"
    # 3 is --status's "past MAX_BACKUP_AGE_HOURS". It used to print
    # "stale : YES -- would alert" and exit 0, so a host that had quietly
    # stopped backing up sailed through this gate.
    case "$s" in
      0) ;;
      3) echo "  STALE: no successful backup within MAX_BACKUP_AGE_HOURS"; rc=1 ;;
      *) echo "  no status: unreachable, sudo refused, not installed, or no config"; rc=1 ;;
    esac
  done
  warn_no_cron
  warn_prereqs
  # A fleet with unscheduled hosts, or hosts that cannot run a backup at all, is
  # not healthy, so --check must not exit 0 on it -- that is the whole point of a
  # mode meant to be run from CI. (During a deploy these stay warnings: a first
  # deploy legitimately lands before the hand-managed config.)
  (( ${#NO_CRON[@]} || ${#PREREQ[@]} )) && rc=1
  exit "$rc"
fi

# ---- local preflight: never ship a script that does not parse ----
bash -n "$SRC_DIR/restic-backup.sh" || { echo "FATAL: local restic-backup.sh has syntax errors" >&2; exit 1; }

# A checkout that is BEHIND its remote is the one local mistake nothing
# downstream calls a mistake. The plan compares checksums, so an older local
# file is an ordinary "push this" action, each host records a routine update,
# and the fleet rolls backwards. The diff pass shows a human the change
# inverted -- which is no guard at all under --yes.
#
# Only a fetch can answer the question. The remote-tracking ref on its own is
# as old as the last fetch, and the machine that has been editing all day is
# precisely the one whose refs are stale.
git_preflight() {
  local up remote behind
  git -C "$SRC_DIR" rev-parse --git-dir >/dev/null 2>&1 || return 0

  git -C "$SRC_DIR" diff --quiet HEAD -- restic-backup.sh excludes restic-backup.cron 2>/dev/null \
    || echo "NOTE: deploying uncommitted local changes."

  up="$(git -C "$SRC_DIR" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)" || return 0
  [[ -n "$up" ]] || return 0                         # no upstream: behaves as it always did
  remote="${up%%/*}"

  # Offline is not a reason to refuse. The fleet is reached over WireGuard, and
  # whether the git remote answers says nothing about whether the hosts do.
  if ! git -C "$SRC_DIR" fetch --quiet "$remote" 2>/dev/null; then
    echo "NOTE: cannot reach $remote; deploying without checking for newer commits."
    return 0
  fi

  behind="$(git -C "$SRC_DIR" rev-list --count "HEAD..$up" 2>/dev/null)" || return 0
  (( behind )) || return 0

  # --dry-run pushes nothing, so it gets the warning and still plans: refusing
  # to show someone what a deploy WOULD do is the wrong answer to "you are out
  # of date".
  if (( DRY_RUN )); then
    echo "WARNING: this checkout is $behind commit(s) behind $up. Planning anyway (--dry-run)."
    return 0
  fi
  if (( ${ALLOW_STALE:-0} )); then
    echo "WARNING: this checkout is $behind commit(s) behind $up, and ALLOW_STALE=1"
    echo "  is set. Every host is being reverted to this older state."
    return 0
  fi

  cat >&2 <<EOF
FATAL: this checkout is $behind commit(s) behind $up.

Deploying now pushes the OLDER files to every host, and nothing downstream
reports it: the plan sees a checksum difference and each host records an
ordinary update.

    git -C $SRC_DIR pull --rebase

If reverting the fleet to this state is the actual intent, say so:

    ALLOW_STALE=1 $0
EOF
  return 1
}
git_preflight || exit 1

# ---- pass 1: plan ----
local_sh="$(sha_of "$SRC_DIR/restic-backup.sh")"
local_ex="$(sha_of "$SRC_DIR/excludes")"
declare -A PLAN=() CRONTMP=() WHY=() SHORT=()
pending=0; unreachable=(); CURRENT_HOST=""
ERRTMP="$(mktemp)"
# The four hand-written cleanup loops this replaces all missed the "Not a
# terminal; re-run with --yes" exit, and any abort from set -e or Ctrl-C.
cleanup_tmp() { rm -f "$ERRTMP" ${CRONTMP[@]+"${CRONTMP[@]}"}; }
trap cleanup_tmp EXIT
# An interrupt between two pushes leaves a host half-deployed, and nothing
# records which one. Say so rather than leaving it to be discovered.
trap 'if [[ -n "$CURRENT_HOST" ]]; then
        printf "\n\nINTERRUPTED while deploying to %s -- that host may be half-updated.\n" "$CURRENT_HOST" >&2
        printf "Re-run ./deploy.sh --host %s to finish it.\n" "$CURRENT_HOST" >&2
      fi
      exit 130' INT TERM

for h in "${HOSTS[@]}"; do
  addr="$(addr_of "$h")"
  # One round trip does the checksums AND the prerequisites. None of these block
  # a push -- a first deploy legitimately precedes the hand-managed config -- but
  # every one of them is a host that installs cleanly and then never backs up,
  # which is the failure this tool is least able to notice afterwards.
  # Keep ssh's own stderr. Discarding it turned every distinct failure -- a
  # refused root login, an unknown host key, a DNS miss -- into the single word
  # "unreachable", which sends you off testing `ssh <host>` by hand as yourself
  # and finding it works: deploy connects as $SSH_USER, not as you.
  : > "$ERRTMP"
  S="$(sudo_for "$addr")"
  # The sudo check is its own statement, before anything whose stderr is
  # discarded. A failing `sudo -n` inside the sha256sum line would be swallowed
  # by that 2>/dev/null and read as "all three files are missing", which is
  # indistinguishable from a fresh host -- so the run would cheerfully plan a
  # full push and only discover the truth while writing.
  remote="$(ssh -n "${SSH_OPTS[@]}" "$addr" "
      ${S}true || exit 111
      ${S}sha256sum $(rq "$SBIN_PATH") $(rq "$CONFIG_DIR/excludes") $(rq "$CRON_PATH") 2>/dev/null
$(prereq_probe "$S")
      true" 2>"$ERRTMP")" || {
    unreachable+=("$h"); PLAN[$h]="unreachable"
    WHY[$h]="$(grep -v '^$' "$ERRTMP" | tail -n1)"
    [[ "${WHY[$h]}" == sudo:* ]] && SHORT[$h]="sudo failed"
    continue; }
  prereq="$(prereq_list "$remote")"
  [[ -n "$prereq" ]] && PREREQ[$h]="$prereq"
  r_sh=$(remote_sha "$remote" "$SBIN_PATH")
  r_ex=$(remote_sha "$remote" "$CONFIG_DIR/excludes")
  r_cr=$(remote_sha "$remote" "$CRON_PATH")

  acts=""
  [[ "$r_sh" == "$local_sh" ]] && (( ! FORCE )) || acts+=" script"
  [[ "$r_ex" == "$local_ex" ]] && (( ! FORCE )) || acts+=" excludes"
  if [[ -n "${CRON_MINUTE[$h]:-}" ]]; then
    tmp="$(mktemp)"; render_cron "${CRON_MINUTE[$h]}" > "$tmp"; CRONTMP[$h]="$tmp"
    [[ "$r_cr" == "$(sha_of "$tmp")" ]] && (( ! FORCE )) || acts+=" cron"
  fi
  PLAN[$h]="${acts# }"
  # "unreachable" is a non-empty PLAN entry but not work: counting it made a run
  # in which every host was down skip "Nothing to do" and prompt to push nothing.
  [[ -n "${PLAN[$h]}" && "${PLAN[$h]}" != unreachable ]] && pending=$(( pending + 1 ))
done

printf '\n%-22s %s\n' "HOST" "TO UPDATE"
for h in "${HOSTS[@]}"; do
  note=""
  [[ "${PLAN[$h]}" == unreachable || -n "${CRON_MINUTE[$h]:-}" ]] || note="   << no CRON_MINUTE"
  printf '%-22s %s%s\n' "$h" "${SHORT[$h]:-${PLAN[$h]:-up to date}}" "$note"
done
if (( ${#unreachable[@]} )); then
  printf '\n%d host(s) could not be planned: %s\n' "${#unreachable[@]}" "${unreachable[*]}"
  for h in "${unreachable[@]}"; do
    printf '  %-20s %s\n' "$h" "${WHY[$h]:-ssh failed without a message}"
  done
  printf '  Deploy connects as %s@ and runs as root through "%s" -- test both:\n' \
    "$SSH_USER" "$SUDO"
  printf '    ssh %s %s %s true\n' \
    "${SSH_OPTS[*]}" "$(addr_of "${unreachable[0]}")" "$SUDO"
  if grep -qi '^sudo:' <<<"${WHY[*]}"; then
    printf '  That is a sudo failure, not a connection failure. Passwordless sudo is\n'
    printf '  required: BatchMode ssh has no terminal to answer a password prompt on.\n'
  fi
fi
warn_no_cron
warn_prereqs

if (( pending == 0 )); then
  echo; echo "Nothing to do."
  (( ${#unreachable[@]} )) && exit 1; exit 0
fi

# The banner at the top of this file promises "a diff shown before anything is
# written", and the whole push-not-pull argument rests on that being true: this
# ships code that runs as root on every host, and the safeguard is a human
# reading what changes. But the diff lived inside the --dry-run branch, which
# exits, so the interactive path went plan table -> prompt -> push, asking for
# approval of a one-word "TO UPDATE" column. Only restic-backup.sh was ever
# diffed, too: a hand-edited remote `excludes` and the rendered cron entry were
# both replaced sight unseen.
DIFF_LINES="${DIFF_LINES:-60}"         # per file; 0 = no limit

# The diff is also this run's record -- --yes suppresses the question, not the
# record -- so colour is decoration and must never be what makes it readable.
# On for a terminal only, and off for NO_COLOR (no-color.org), a dumb TERM, and
# any redirection into a file or a CI log, where the escapes would be noise in
# the one artefact left behind.
if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != dumb ]]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_CYA=$'\033[36m'; C_BLD=$'\033[1m'; C_OFF=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_CYA=""; C_BLD=""; C_OFF=""
fi

# NOT `diff --color=always`: that is GNU diffutils >= 3.4, and this half of the
# tool runs on whatever machine the operator is sitting at. Everywhere else the
# unknown option makes diff exit 2 having printed nothing, and diff_one reads an
# empty output as "identical -- forced push" -- so the unsupported flag would
# not lose the colour, it would lose the diff, on exactly the pass whose whole
# purpose is showing a human what is about to run as root on every host.
#
# Every line carries its own reset, so truncating at DIFF_LINES cannot leave a
# colour bleeding into the rest of the run. The escapes cross `awk -v` intact
# because they are literal ESC characters with no backslash left for awk to
# reinterpret -- the hazard render_cron's -v values do have.
#
# Ordered: ---/+++ are the file headers, not a removal and an addition.
colorize_diff() {
  [[ -n "$C_OFF" ]] || { cat; return 0; }
  awk -v r="$C_RED" -v g="$C_GRN" -v c="$C_CYA" -v b="$C_BLD" -v o="$C_OFF" '
    /^(---|\+\+\+)/ { print b $0 o; next }
    /^@@/            { print c $0 o; next }
    /^\+/            { print g $0 o; next }
    /^-/             { print r $0 o; next }
                     { print }
  '
}

diff_one() {                           # diff_one <addr> <host> <remote-path> <local-file> [label]
  local addr="$1" host="$2" remote="$3" src="$4" label="${5:-local:$(basename "$4")}" out n
  out="$(ssh -n "${SSH_OPTS[@]}" "$addr" "$(sudo_for "$addr")cat $(rq "$remote") 2>/dev/null" \
         | diff -u --label "$host:$remote" --label "$label" - "$src" | colorize_diff || true)"
  printf '\n%s--- %s: %s ---%s\n' "$C_BLD" "$host" "$remote" "$C_OFF"
  if [[ -z "$out" ]]; then
    printf '  (identical -- forced push)\n'
    return 0
  fi
  n=$(printf '%s\n' "$out" | wc -l)
  if (( DIFF_LINES > 0 && n > DIFF_LINES )); then
    # sed, not head: head exits at the limit and the SIGPIPE that gives printf
    # fails the pipeline under `set -o pipefail`, which would abort the deploy
    # on the first diff long enough to be truncated.
    printf '%s\n' "$out" | sed -n "1,${DIFF_LINES}p"
    printf '  ... %d more lines (DIFF_LINES=0 to see all)\n' $(( n - DIFF_LINES ))
  else
    printf '%s\n' "$out"
  fi
  return 0
}

show_diffs() {
  local h a
  for h in "${HOSTS[@]}"; do
    [[ -n "${PLAN[$h]}" && "${PLAN[$h]}" != unreachable ]] || continue
    a="$(addr_of "$h")"
    [[ "${PLAN[$h]}" == *script*   ]] && diff_one "$a" "$h" "$SBIN_PATH" "$SRC_DIR/restic-backup.sh"
    [[ "${PLAN[$h]}" == *excludes* ]] && diff_one "$a" "$h" "$CONFIG_DIR/excludes" "$SRC_DIR/excludes"
    [[ "${PLAN[$h]}" == *cron*     ]] && diff_one "$a" "$h" "$CRON_PATH" "${CRONTMP[$h]}" \
                                                  "local:restic-backup.cron (minute ${CRON_MINUTE[$h]:-?})"
  done
  return 0
}

if (( DRY_RUN )); then
  show_diffs
  # Non-zero if anything could not be planned, so --dry-run is usable as a gate.
  (( ${#unreachable[@]} )) && exit 1; exit 0
fi

# The diff is not part of the prompt -- it is the record of what root-executed
# code this run changed on every host, and the whole case for pushing rather
# than letting clients pull rests on it being shown. --yes suppresses the
# QUESTION, not the record: it is aimed at cron and CI, which is exactly where
# nobody is watching and the log is all there will be afterwards.
(( ASSUME_YES )) || [[ -t 0 ]] || { echo "Not a terminal; re-run with --yes." >&2; exit 1; }
show_diffs
if (( ! ASSUME_YES )); then
  read -r -p $'\nPush to the hosts listed above? [y/N] ' ans
  [[ "$ans" == [yY]* ]] || { echo "Aborted."; exit 1; }
fi

# ---- pass 2: apply ----
# install-then-rename, never a plain copy over the target: restic-backup.sh may
# be RUNNING, and bash reads its own source as it goes -- overwriting it in
# place makes a live run execute whatever lands at that offset. rename(2) hands
# the running process its old inode and is atomic.
# The staging file lives in the DESTINATION directory, which is root-owned, and
# the content arrives on ssh's stdin rather than through scp. It used to be
# staged at /tmp/.deploy-$$-$RANDOM, which is a guessable name in a directory
# every local user can write: $$ is fixed for a whole deploy run and visible in
# the name of the first staged file, $RANDOM is 15 bits, and scp opens its
# destination O_CREAT|O_TRUNC as root with no O_EXCL and no O_NOFOLLOW. Any
# unprivileged user on a target could pre-create the 32768 candidate symlinks,
# have root truncate and fill whatever one of them pointed at, and then have
# `install` copy back through it into /usr/local/sbin/restic-backup.sh -- which
# is to say, choose the contents of an hourly root cron job. /tmp being sticky
# does not help when the name does not exist yet.
# `tee`, not `cat >`: with an unprivileged login the redirection is performed by
# the login shell, so `sudo cat > "$dest.new"` opens the staging file as the
# LOGIN user in a root-owned directory -- permission denied, and where the
# directory happens to be writable, a file root then renames into place that the
# login user owned for the length of the push. Only the writing process may be
# the privileged one. The umask above still applies: sudo takes the union of the
# caller's umask and its own, so the staged file is created 600 either way.
push() {                               # push <local> <remote-dest> <mode> [dir-mode]
  local src="$1" dest="$2" mode="$3" dirmode="${4:-755}" S
  S="$(sudo_for "$addr")"
  ssh "${SSH_OPTS[@]}" "$addr" "
    set -eu
    dest=$(rq "$dest"); dir=\$(dirname \"\$dest\")
    [ -d \"\$dir\" ] || ${S}install -d -m $(rq "$dirmode") \"\$dir\"
    umask 077
    ${S}tee \"\$dest.new\" >/dev/null
    ${S}chmod $(rq "$mode") \"\$dest.new\"
    ${S}mv -f \"\$dest.new\" \"\$dest\"
  " < "$src"
}

rc=0
for h in "${HOSTS[@]}"; do
  [[ -n "${PLAN[$h]}" && "${PLAN[$h]}" != unreachable ]] || continue
  addr="$(addr_of "$h")"; CURRENT_HOST="$h"
  printf '\n=== %s ===\n' "$h"
  ok=1
  # Ordered, and each step gated on the one before it. The three pushes used to
  # run unconditionally, recording ok=0 without acting on it, so a script push
  # that failed -- a full disk, a read-only /usr, a connection dropped mid-run --
  # was still followed by the cron entry. That leaves an hourly root job pointing
  # at a script that is not there: the host backs up nothing, and since the
  # staleness alerting only ever runs FROM that job, neither the host nor this
  # tool ever says so. It is the same silent-no-backup state the NO_CRON warning
  # exists to prevent, reached through a different door.
  #
  # Cron therefore goes last and only if everything it depends on landed.
  if [[ "${PLAN[$h]}" == *script* ]]; then
    push "$SRC_DIR/restic-backup.sh" "$SBIN_PATH" 755 \
      || { ok=0; echo "  FAILED to push $SBIN_PATH"; }
  fi
  if (( ok )) && [[ "${PLAN[$h]}" == *excludes* ]]; then
    push "$SRC_DIR/excludes" "$CONFIG_DIR/excludes" 644 700 \
      || { ok=0; echo "  FAILED to push $CONFIG_DIR/excludes"; }
  fi
  if (( ok )) && [[ "${PLAN[$h]}" == *cron* ]]; then
    push "${CRONTMP[$h]}" "$CRON_PATH" 644 \
      || { ok=0; echo "  FAILED to push $CRON_PATH -- this host has no schedule"; }
  fi
  if (( ok )); then
    ssh -n "${SSH_OPTS[@]}" "$addr" \
        "$(sudo_for "$addr")env RESTIC_CONFIG_DIR=$(rq "$CONFIG_DIR") $(rq "$SBIN_PATH") --status" \
      || { echo "  (--status failed)"; rc=1; }
  else
    rc=1
    if [[ "${PLAN[$h]}" == *cron* ]]; then
      echo "  Skipped the remaining steps, INCLUDING the cron entry -- deliberately:"
      echo "  a schedule without a working script is a host that silently never backs up."
    else
      echo "  Skipped the remaining steps for this host."
    fi
  fi
done

CURRENT_HOST=""
(( ${#unreachable[@]} )) && rc=1
exit "$rc"
