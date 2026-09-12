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
# What it NEVER touches:
#                    config and encryption-pw  -- secrets, per host, hand-managed
#                    pre-backup                -- per-host hook, hand-managed
#
#   ./deploy.sh                 plan, show diffs, ask, then apply
#   ./deploy.sh --check         change nothing; report each host's --status
#   ./deploy.sh --dry-run       plan and diff only
#   DIFF_LINES=0 ./deploy.sh    show every diff line (default: first 60 per file)
#   ./deploy.sh --host srv01    just that host (repeatable)
#   ./deploy.sh --yes           skip the confirmation prompt; required when
#                               stdin is not a terminal (cron, CI)
#   ./deploy.sh --force         push even where the checksums already match,
#                               to undo a hand-edit made on a target
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

prereq_probe() {
  cat <<EOF
command -v restic >/dev/null 2>&1 || echo '#PRE restic is not installed'
command -v flock  >/dev/null 2>&1 || echo '#PRE flock is missing (util-linux)'
command -v curl   >/dev/null 2>&1 || echo '#PRE curl is missing (health check, ntfy, dead-mans switch)'
[ -f $(rq "$CONFIG_DIR/config") ]        || echo '#PRE no config'
[ -r $(rq "$CONFIG_DIR/encryption-pw") ] || echo '#PRE no encryption-pw'
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
    out=$(ssh -n "${SSH_OPTS[@]}" "$(addr_of "$h")" "$(prereq_probe)
         RESTIC_CONFIG_DIR=$(rq "$CONFIG_DIR") $(rq "$SBIN_PATH") --status" 2>&1) && s=0 || s=$?
    prereq="$(prereq_list "$out")"
    [[ -n "$prereq" ]] && PREREQ[$h]="$prereq"
    sed '/^#PRE /d' <<<"$out"
    # 3 is --status's "past MAX_BACKUP_AGE_HOURS". It used to print
    # "stale : YES -- would alert" and exit 0, so a host that had quietly
    # stopped backing up sailed through this gate.
    case "$s" in
      0) ;;
      3) echo "  STALE: no successful backup within MAX_BACKUP_AGE_HOURS"; rc=1 ;;
      *) echo "  no status: unreachable, not installed, or no config"; rc=1 ;;
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
if git -C "$SRC_DIR" rev-parse --git-dir >/dev/null 2>&1 \
   && ! git -C "$SRC_DIR" diff --quiet HEAD -- restic-backup.sh excludes restic-backup.cron 2>/dev/null; then
  echo "NOTE: deploying uncommitted local changes."
fi

# ---- pass 1: plan ----
local_sh="$(sha_of "$SRC_DIR/restic-backup.sh")"
local_ex="$(sha_of "$SRC_DIR/excludes")"
declare -A PLAN=() CRONTMP=()
pending=0; unreachable=(); CURRENT_HOST=""
# The four hand-written cleanup loops this replaces all missed the "Not a
# terminal; re-run with --yes" exit, and any abort from set -e or Ctrl-C.
cleanup_tmp() { rm -f ${CRONTMP[@]+"${CRONTMP[@]}"}; }
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
  remote="$(ssh -n "${SSH_OPTS[@]}" "$addr" "
      sha256sum $(rq "$SBIN_PATH") $(rq "$CONFIG_DIR/excludes") $(rq "$CRON_PATH") 2>/dev/null
$(prereq_probe)
      true" 2>/dev/null)" || {
    unreachable+=("$h"); PLAN[$h]="unreachable"; continue; }
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
  printf '%-22s %s%s\n' "$h" "${PLAN[$h]:-up to date}" "$note"
done
(( ${#unreachable[@]} )) && printf '\n%d host(s) unreachable: %s\n' "${#unreachable[@]}" "${unreachable[*]}"
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

diff_one() {                           # diff_one <addr> <host> <remote-path> <local-file> [label]
  local addr="$1" host="$2" remote="$3" src="$4" label="${5:-local:$(basename "$4")}" out n
  out="$(ssh -n "${SSH_OPTS[@]}" "$addr" "cat $(rq "$remote") 2>/dev/null" \
         | diff -u --label "$host:$remote" --label "$label" - "$src" || true)"
  printf '\n--- %s: %s ---\n' "$host" "$remote"
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
push() {                               # push <local> <remote-dest> <mode> [dir-mode]
  local src="$1" dest="$2" mode="$3" dirmode="${4:-755}"
  ssh "${SSH_OPTS[@]}" "$addr" "
    set -eu
    dest=$(rq "$dest"); dir=\$(dirname \"\$dest\")
    [ -d \"\$dir\" ] || install -d -m $(rq "$dirmode") \"\$dir\"
    umask 077
    cat > \"\$dest.new\"
    chmod $(rq "$mode") \"\$dest.new\"
    mv -f \"\$dest.new\" \"\$dest\"
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
        "RESTIC_CONFIG_DIR=$(rq "$CONFIG_DIR") $(rq "$SBIN_PATH") --status" \
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
