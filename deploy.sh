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
#   ./deploy.sh --host srv01    just that host (repeatable)
# ============================================================================

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${DEPLOY_CONF:-$SRC_DIR/deploy.conf}"

CHECK_ONLY=0; DRY_RUN=0; ASSUME_YES=0; FORCE=0
declare -a ONLY_HOSTS=()
usage() { sed -n '4,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
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

addr_of() { [[ "$1" == *@* ]] && printf '%s' "$1" || printf '%s@%s' "$SSH_USER" "$1"; }
sha_of()  { sha256sum "$1" | awk '{print $1}'; }

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
    if ! ssh "${SSH_OPTS[@]}" "$(addr_of "$h")" "'$SBIN_PATH' --status" 2>&1; then
      echo "  no status: unreachable, not installed, or no config"; rc=1
    fi
  done
  warn_no_cron
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
pending=0; unreachable=()

for h in "${HOSTS[@]}"; do
  addr="$(addr_of "$h")"
  remote="$(ssh "${SSH_OPTS[@]}" "$addr" \
      "sha256sum '$SBIN_PATH' '$CONFIG_DIR/excludes' '$CRON_PATH' 2>/dev/null; true" 2>/dev/null)" || {
    unreachable+=("$h"); PLAN[$h]="unreachable"; continue; }
  r_sh=$(awk -v p="$SBIN_PATH"            '$2==p{print $1}' <<<"$remote")
  r_ex=$(awk -v p="$CONFIG_DIR/excludes"  '$2==p{print $1}' <<<"$remote")
  r_cr=$(awk -v p="$CRON_PATH"            '$2==p{print $1}' <<<"$remote")

  acts=""
  [[ "$r_sh" == "$local_sh" ]] && (( ! FORCE )) || acts+=" script"
  [[ "$r_ex" == "$local_ex" ]] && (( ! FORCE )) || acts+=" excludes"
  if [[ -n "${CRON_MINUTE[$h]:-}" ]]; then
    tmp="$(mktemp)"; render_cron "${CRON_MINUTE[$h]}" > "$tmp"; CRONTMP[$h]="$tmp"
    [[ "$r_cr" == "$(sha_of "$tmp")" ]] && (( ! FORCE )) || acts+=" cron"
  fi
  PLAN[$h]="${acts# }"
  [[ -n "${PLAN[$h]}" ]] && pending=$(( pending + 1 ))
done

printf '\n%-22s %s\n' "HOST" "TO UPDATE"
for h in "${HOSTS[@]}"; do
  note=""
  [[ "${PLAN[$h]}" == unreachable || -n "${CRON_MINUTE[$h]:-}" ]] || note="   << no CRON_MINUTE"
  printf '%-22s %s%s\n' "$h" "${PLAN[$h]:-up to date}" "$note"
done
(( ${#unreachable[@]} )) && printf '\n%d host(s) unreachable: %s\n' "${#unreachable[@]}" "${unreachable[*]}"
warn_no_cron

if (( pending == 0 )); then
  echo; echo "Nothing to do."
  for t in "${CRONTMP[@]}"; do rm -f "$t"; done
  (( ${#unreachable[@]} )) && exit 1; exit 0
fi

if (( DRY_RUN )); then
  for h in "${HOSTS[@]}"; do
    [[ "${PLAN[$h]}" == *script* ]] || continue
    printf '\n--- %s: %s ---\n' "$h" "$SBIN_PATH"
    ssh "${SSH_OPTS[@]}" "$(addr_of "$h")" "cat '$SBIN_PATH' 2>/dev/null" \
      | diff -u - "$SRC_DIR/restic-backup.sh" | head -40 || true
  done
  for t in "${CRONTMP[@]}"; do rm -f "$t"; done
  exit 0
fi

if (( ! ASSUME_YES )); then
  [[ -t 0 ]] || { echo "Not a terminal; re-run with --yes." >&2; exit 1; }
  read -r -p $'\nPush to the hosts listed above? [y/N] ' ans
  [[ "$ans" == [yY]* ]] || { echo "Aborted."; for t in "${CRONTMP[@]}"; do rm -f "$t"; done; exit 1; }
fi

# ---- pass 2: apply ----
# install-then-rename, never a plain copy over the target: restic-backup.sh may
# be RUNNING, and bash reads its own source as it goes -- overwriting it in
# place makes a live run execute whatever lands at that offset. rename(2) hands
# the running process its old inode and is atomic.
push() {                               # <local> <remote-dest> <mode>
  local src="$1" dest="$2" mode="$3" tmp="/tmp/.deploy-$$-${RANDOM}"
  scp "${SSH_OPTS[@]}" -q "$src" "$addr:$tmp"
  ssh "${SSH_OPTS[@]}" "$addr" \
    "install -D -m '$mode' '$tmp' '$dest.new' && mv -f '$dest.new' '$dest' && rm -f '$tmp'"
}

rc=0
for h in "${HOSTS[@]}"; do
  [[ -n "${PLAN[$h]}" && "${PLAN[$h]}" != unreachable ]] || continue
  addr="$(addr_of "$h")"
  printf '\n=== %s ===\n' "$h"
  ok=1
  [[ "${PLAN[$h]}" == *script*   ]] && { push "$SRC_DIR/restic-backup.sh" "$SBIN_PATH" 755        || ok=0; }
  [[ "${PLAN[$h]}" == *excludes* ]] && { push "$SRC_DIR/excludes" "$CONFIG_DIR/excludes" 644      || ok=0; }
  [[ "${PLAN[$h]}" == *cron*     ]] && { push "${CRONTMP[$h]}" "$CRON_PATH" 644                   || ok=0; }
  if (( ok )); then
    ssh "${SSH_OPTS[@]}" "$addr" "'$SBIN_PATH' --status" || { echo "  (--status failed)"; rc=1; }
  else
    echo "  FAILED"; rc=1
  fi
done

for t in "${CRONTMP[@]}"; do rm -f "$t"; done
(( ${#unreachable[@]} )) && rc=1
exit "$rc"
