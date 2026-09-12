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
# SKIPPING IS SILENT; AGE IS WHAT ALERTS. Every path that declines to back up
# (metered link, tunnel down, lock held) exits through stale_exit(), which pages
# you once the last SUCCESSFUL backup is older than MAX_BACKUP_AGE_HOURS=36. A
# host that quietly stops backing up therefore alerts LOCALLY, instead of relying
# on the external dead-man's switch to notice eventually. That is what makes a
# silent skip safe: it can no longer hide.
#
# $CONFIG_DIR/.last-success is written ONLY after `restic backup` returns 0, and
# is the sole record of when a backup last worked.
#
# Notifications are throttled to match: only the first failure after a success,
# and the crossing of MAX_BACKUP_AGE, page you (see notify_failure).
# ---------------------------------------------------------------------------
#
# Requires restic >= 0.16 (--retry-lock). Keep client restic <= maintenance host.
# ============================================================================

export PATH="/usr/local/bin:/usr/bin:/bin:${PATH:-}"

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
    read -r v < "$f" || v=0
    [[ "$v" =~ ^[0-9]+$ ]] || v=0
  fi
  printf '%s' "$v"
}

# ---- Load per-host config ----
CONFIG_DIR="${RESTIC_CONFIG_DIR:-$HOME/.config/restic}"
[[ -f "$CONFIG_DIR/config" ]] || { echo "FATAL: missing $CONFIG_DIR/config" >&2; exit 1; }
# shellcheck disable=SC1091
source "$CONFIG_DIR/config"
# NOTE: restic authenticates to rest-server via HTTP Basic Auth on EVERY request --
# there is no login step. Credentials come from RESTIC_REST_USERNAME / RESTIC_REST_PASSWORD
# (set in config), and are DISTINCT from RESTIC_PASSWORD_FILE (the encryption password).

# ---- Defaults + required-value guards ----
declare -p BACKUP_PATHS &>/dev/null || { echo "FATAL: BACKUP_PATHS not set in config" >&2; exit 1; }
(( ${#BACKUP_PATHS[@]} )) || { echo "FATAL: BACKUP_PATHS is empty" >&2; exit 1; }
declare -p EXTRA_BACKUP_ARGS &>/dev/null || EXTRA_BACKUP_ARGS=()  # e.g. (--one-file-system)
EXCLUDE_FILE="${EXCLUDE_FILE:-$CONFIG_DIR/excludes}"
DUMP_DIR="${DUMP_DIR:-$CONFIG_DIR/db-dumps}"
LOCK_WAIT="${LOCK_WAIT:-15m}"
SKIP_IF_METERED="${SKIP_IF_METERED:-false}"

# Staleness. Hours; 0 disables the rule.
MAX_BACKUP_AGE_HOURS="${MAX_BACKUP_AGE_HOURS:-36}"   # 0 = never hard-fail on age
NOTIFY_REPEAT_HOURS="${NOTIFY_REPEAT_HOURS:-12}"     # re-page interval while stale

# WireGuard self-heal: bounce the tunnel once if the backend is unreachable.
WG_INTERFACE="${WG_INTERFACE:-}"                     # "" = never touch the tunnel
WG_RESTART_CMD="${WG_RESTART_CMD:-}"                 # overrides the built-in logic
WG_SETTLE_SECS="${WG_SETTLE_SECS:-5}"

if declare -p SKIP_IF_UNREACHABLE &>/dev/null; then
  log "WARN: SKIP_IF_UNREACHABLE is obsolete and ignored -- an unreachable backend is"
  log "WARN: now always a silent skip, and MAX_BACKUP_AGE_HOURS decides when that"
  log "WARN: becomes a failure. Delete it from $CONFIG_DIR/config."
fi

for _v in MAX_BACKUP_AGE_HOURS NOTIFY_REPEAT_HOURS WG_SETTLE_SECS; do
  declare -n _r="$_v"
  if [[ ! "$_r" =~ ^[0-9]+$ ]]; then log "WARN: $_v='$_r' is not an integer; using 0"; _r=0; fi
done
unset -n _r; unset _v

MAX_AGE_SEC=$(( MAX_BACKUP_AGE_HOURS * 3600 ))
NOTIFY_REPEAT_SEC=$(( NOTIFY_REPEAT_HOURS * 3600 ))

# State. Cheap, local, and the only thing that survives a reboot: .last-success
# is what every staleness decision is measured against.
LAST_SUCCESS_FILE="$CONFIG_DIR/.last-success"
FIRST_SEEN_FILE="$CONFIG_DIR/.first-seen"
NOTIFY_STATE_FILE="$CONFIG_DIR/.notify-state"
ALERT_AGE_SEC=-1                       # set for real below; safe default for the ERR trap

# ntfy (failure-only; success is intentionally silent)
NTFY_URL="${NTFY_URL:-}"
NTFY_TOPIC_HIGH="${NTFY_TOPIC_HIGH:-backups-high}"
NTFY_TOKEN="${NTFY_TOKEN:-}"
PING_URL="${RESTIC_PING_URL:-}"

# ---- Helpers ----
ping_dms() { [[ -n "$PING_URL" ]] || return 0; curl -fsS -m 10 --retry 3 "$1" >/dev/null 2>&1 || true; }

ntfy() {
  local topic="$1" priority="$2" tags="$3" title="$4" body="$5"
  local args=(-H "Title: $title" -H "Priority: $priority" -H "Tags: $tags")
  [[ -n "$NTFY_TOKEN" ]] && args+=(-H "Authorization: Bearer $NTFY_TOKEN")
  curl -fsS -m 15 --retry 3 "${args[@]}" --data-binary "$body" \
    "$NTFY_URL/$topic" >/dev/null 2>&1 || log "WARN: ntfy send failed"
}

# Hourly invocation means a stuck host would push 24 urgent notifications a day.
# Policy, keyed off $NOTIFY_STATE_FILE ("<first> <last> <hard>", removed on every
# success):
#   - first failure after a success  -> always push (breakage is actionable NOW)
#   - later failures, still under MAX_BACKUP_AGE -> log + DMS only
#   - crossing MAX_BACKUP_AGE        -> push once more (escalation)
#   - beyond that                    -> push at most every NOTIFY_REPEAT_HOURS
# Returns 0 if this event should be pushed. Always records the attempt.
notify_should_push() {
  local hard="$1" now first last hardflag
  now=$(date +%s)
  if [[ ! -s "$NOTIFY_STATE_FILE" ]]; then
    printf '%s %s %s\n' "$now" "$now" "$hard" > "$NOTIFY_STATE_FILE"
    return 0
  fi
  first=0; last=0; hardflag=0
  read -r first last hardflag < "$NOTIFY_STATE_FILE" || true
  [[ "$first"    =~ ^[0-9]+$ ]] || first="$now"
  [[ "$last"     =~ ^[0-9]+$ ]] || last=0
  [[ "$hardflag" =~ ^[01]$   ]] || hardflag=0
  if (( hard == 1 )) && { (( hardflag == 0 )) || (( now - last >= NOTIFY_REPEAT_SEC )); }; then
    printf '%s %s 1\n' "$first" "$now" > "$NOTIFY_STATE_FILE"
    return 0
  fi
  printf '%s %s %s\n' "$first" "$last" "$hardflag" > "$NOTIFY_STATE_FILE"
  return 1
}

notify_failure() {
  local stage="$1" code="$2" output="$3" hard=0 last_txt="never"
  ping_dms "$PING_URL/fail"
  if (( MAX_AGE_SEC > 0 && ALERT_AGE_SEC >= MAX_AGE_SEC )); then hard=1; fi
  if (( ${LAST_SUCCESS:-0} > 0 )); then last_txt="$(date -d "@$LAST_SUCCESS" '+%Y-%m-%d %H:%M') ($(fmt_age "$ALERT_AGE_SEC") ago)"; fi
  if ! notify_should_push "$hard"; then
    log "NOTICE: '$stage' failed (exit $code); notification suppressed (already alerted, age $(fmt_age "$ALERT_AGE_SEC"))"
    return 0
  fi
  ntfy "$NTFY_TOPIC_HIGH" urgent rotating_light \
    "Backup FAILED on $(hostname) ($stage)" \
"Host:  $(hostname)
Stage: $stage
Exit:  $code
Last good backup: $last_txt
$(printf '%s' "$output" | tail -c 1500)"
  command -v notify-send >/dev/null 2>&1 \
    && notify-send -u critical "restic backup failed" "$stage (exit $code)" 2>/dev/null || true
}

run_step() {
  local stage="$1"; shift
  log ">>> $stage"
  set +e
  local out; out="$("$@" 2>&1)"; local rc=$?
  set -e
  printf '%s\n' "$out"
  if (( rc != 0 )); then
    log "ERROR during '$stage' (exit $rc)"
    notify_failure "$stage" "$rc" "$out"
    exit "$rc"
  fi
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
# empty output) notify and abort the whole backup -- same policy as before:
# better no backup than a backup with a half-dumped database.
db_dump_to() {
  local name; name="$(_slug "$1")"; shift
  local out="$DUMP_DIR/$name.sql" tmp="$DUMP_DIR/$name.sql.tmp" err="$DUMP_DIR/$name.sql.err"
  log ">>> dump $name"
  set +e; "$@" >"$tmp" 2>"$err"; local rc=$?; set -e
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
#  AGE OF THE LAST SUCCESSFUL BACKUP
#
#  ALERT_AGE_SEC is measured from .first-seen when there has never been a
#  success -- otherwise a host installed this morning would page you as "36h
#  stale" on day one.
# ============================================================================
NOW=$(date +%s)
LAST_SUCCESS=$(read_epoch "$LAST_SUCCESS_FILE")
FIRST_SEEN=$(read_epoch "$FIRST_SEEN_FILE")
(( FIRST_SEEN > 0 )) || FIRST_SEEN=$NOW

if (( LAST_SUCCESS > 0 )); then
  ALERT_AGE_SEC=$(( NOW - LAST_SUCCESS ))
  if (( ALERT_AGE_SEC < 0 )); then
    log "WARN: .last-success lies in the future (clock skew?); treating as just-run."
    ALERT_AGE_SEC=0
  fi
else
  ALERT_AGE_SEC=$(( NOW - FIRST_SEEN ))
  if (( ALERT_AGE_SEC < 0 )); then ALERT_AGE_SEC=0; fi
fi

# Every exit path that did NOT back up comes through here, so that a host which
# quietly stops backing up still alerts -- locally, without waiting on the
# external dead-man's switch. Exits 1 when stale (a real failure), else 0.
stale_exit() {
  local reason="$1"
  if (( MAX_AGE_SEC > 0 && ALERT_AGE_SEC >= MAX_AGE_SEC )); then
    log "STALE: no successful backup for $(fmt_age "$ALERT_AGE_SEC") (limit ${MAX_BACKUP_AGE_HOURS}h)."
    notify_failure "stale: $reason" 1 \
"No successful backup for $(fmt_age "$ALERT_AGE_SEC") -- limit is ${MAX_BACKUP_AGE_HOURS}h.
This run did not back up: $reason"
    exit 1
  fi
  exit 0
}

# ---- Single-instance lock ----
# The newcomer exits quietly -- but still through stale_exit, so a run wedged for
# days is not mistaken for a healthy host.
if command -v flock >/dev/null 2>&1; then
  exec 9>"$CONFIG_DIR/.lock"
  flock -n 9 || { log "Another run holds the lock; exiting."; stale_exit "another run holds the lock"; }
fi

if [[ ! -s "$FIRST_SEEN_FILE" ]]; then printf '%s\n' "$FIRST_SEEN" > "$FIRST_SEEN_FILE"; fi

# ---- Network gate ----
# Only knob left: skip metered links (cellular cost). Reachability of 10.0.0.2
# below is the implicit "is the WG tunnel up?" gate.
link_is_metered() {                    # metered flag on the default-route iface
  command -v nmcli >/dev/null 2>&1 || return 1
  local dev; dev=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
  [[ -n "$dev" ]] || return 1
  nmcli -t -f GENERAL.METERED device show "$dev" 2>/dev/null | grep -qi ':yes'
}

if [[ "$SKIP_IF_METERED" == "true" ]] && link_is_metered; then
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
  if [[ -n "$WG_RESTART_CMD" ]]; then
    log "WG: running WG_RESTART_CMD"
    if ! bash -c "$WG_RESTART_CMD"; then log "WG: WG_RESTART_CMD failed."; return 1; fi
    sleep "$WG_SETTLE_SECS"; return 0
  fi
  [[ -n "$WG_INTERFACE" ]] || return 1
  # No default route means the host is simply offline: `wg-quick up` could not
  # resolve the endpoint anyway, and a failed up() after a successful down()
  # leaves the tunnel DOWN -- strictly worse than what we started with.
  if ! ip route show default 2>/dev/null | grep -q .; then
    log "WG: no default route -- host is offline; leaving $WG_INTERFACE alone."
    return 1
  fi
  # Never run wg-quick behind systemd's back: it would leave the unit thinking
  # the interface is still up.
  if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet "wg-quick@$WG_INTERFACE"; then
    log "WG: restarting wg-quick@$WG_INTERFACE (systemd-managed)"
    if ! systemctl restart "wg-quick@$WG_INTERFACE"; then log "WG: systemctl restart failed."; return 1; fi
  elif command -v wg-quick >/dev/null 2>&1; then
    log "WG: bouncing $WG_INTERFACE with wg-quick"
    wg-quick down "$WG_INTERFACE" >/dev/null 2>&1 || true      # may already be down
    if ! wg-quick up "$WG_INTERFACE"; then
      log "WG: 'wg-quick up $WG_INTERFACE' FAILED -- the tunnel is now DOWN."
      return 1
    fi
  else
    log "WG: neither a wg-quick@$WG_INTERFACE unit nor a wg-quick binary; cannot restart."
    return 1
  fi
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
cleanup_dumps() { rm -rf "${DUMP_DIR:?}"/* 2>/dev/null || true; }
if _have_db_config || [[ -x "$PRE_BACKUP_HOOK" ]]; then
  mkdir -p "$DUMP_DIR"; chmod 700 "$DUMP_DIR"
  trap 'cleanup_dumps' EXIT
  cleanup_dumps                       # clear any junk a crashed run left
  __um=$(umask); umask 077            # dumps are 0600
  run_db_dumps
  umask "$__um"
  [[ -x "$PRE_BACKUP_HOOK" ]] && { export DUMP_DIR; run_step "pre-backup-hook" "$PRE_BACKUP_HOOK"; }
  # Any artifact counts, not just *.sql -- the hook is generic and may write
  # anything. (A failing compgen here is exempt from set -e: it precedes the &&.)
  compgen -G "$DUMP_DIR/*" >/dev/null && BACKUP_PATHS+=("$DUMP_DIR")
fi

# ---- Self-heal stale locks in this client's subrepo (stale-only; safe) ----
run_step "unlock" restic unlock

# ---- Backup ----
run_step "backup" restic backup \
  --retry-lock "$LOCK_WAIT" \
  --exclude-caches \
  --exclude-file "$EXCLUDE_FILE" \
  "${EXTRA_BACKUP_ARGS[@]}" \
  "${BACKUP_PATHS[@]}"

# No forget/prune/check here (append-only; retention lives on the maintenance host).

# ---- Record success ----
# .last-success is written ONLY here, and only after restic returned 0. Every
# staleness decision reads it; a lock-skip or a failed run must never touch it,
# or a wedged host would look freshly backed up.
printf '%s\n' "$(date +%s)" > "$LAST_SUCCESS_FILE"
rm -f "$NOTIFY_STATE_FILE"            # failure streak is over; next failure pages again

log "Backup complete."
ping_dms "$PING_URL"
