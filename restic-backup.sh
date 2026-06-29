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
# Requires restic >= 0.16 (--retry-lock). Keep client restic <= maintenance host.
# ============================================================================

export PATH="/usr/local/bin:/usr/bin:/bin:${PATH:-}"

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
declare -p DB_NAMES &>/dev/null || DB_NAMES=()
declare -p EXTRA_BACKUP_ARGS &>/dev/null || EXTRA_BACKUP_ARGS=()  # e.g. (--one-file-system)
EXCLUDE_FILE="${EXCLUDE_FILE:-$CONFIG_DIR/excludes}"
DUMP_DIR="${DUMP_DIR:-$CONFIG_DIR/db-dumps}"
LOCK_WAIT="${LOCK_WAIT:-15m}"
SKIP_IF_METERED="${SKIP_IF_METERED:-false}"
SKIP_IF_UNREACHABLE="${SKIP_IF_UNREACHABLE:-false}"

# ntfy (failure-only; success is intentionally silent)
NTFY_URL="${NTFY_URL:-}"
NTFY_TOPIC_HIGH="${NTFY_TOPIC_HIGH:-backups-high}"
NTFY_TOKEN="${NTFY_TOKEN:-}"
PING_URL="${RESTIC_PING_URL:-}"

# ---- Helpers ----
log() { printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*"; }
ping_dms() { [[ -n "$PING_URL" ]] || return 0; curl -fsS -m 10 --retry 3 "$1" >/dev/null 2>&1 || true; }

ntfy() {
  local topic="$1" priority="$2" tags="$3" title="$4" body="$5"
  local args=(-H "Title: $title" -H "Priority: $priority" -H "Tags: $tags")
  [[ -n "$NTFY_TOKEN" ]] && args+=(-H "Authorization: Bearer $NTFY_TOKEN")
  curl -fsS -m 15 --retry 3 "${args[@]}" --data-binary "$body" \
    "$NTFY_URL/$topic" >/dev/null 2>&1 || log "WARN: ntfy send failed"
}

notify_failure() {
  local stage="$1" code="$2" output="$3"
  ping_dms "$PING_URL/fail"
  ntfy "$NTFY_TOPIC_HIGH" urgent rotating_light \
    "Backup FAILED on $(hostname) ($stage)" \
"Host:  $(hostname)
Stage: $stage
Exit:  $code
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

# ---- Single-instance lock ----
if command -v flock >/dev/null 2>&1; then
  exec 9>"$CONFIG_DIR/.lock"
  flock -n 9 || { log "Another run holds the lock; exiting."; exit 0; }
fi

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
  exit 0
fi

# ---- Backend reachable? (10.0.0.2 is routable only through WireGuard) ----
if [[ -n "${REST_HEALTH_URL:-}" ]] && ! curl -sS -o /dev/null -m 8 "$REST_HEALTH_URL"; then
  if [[ "$SKIP_IF_UNREACHABLE" == "true" ]]; then
    log "Backend $REST_HEALTH_URL unreachable (WG down?); skipping (not a failure)."; exit 0
  fi
  log "Backend $REST_HEALTH_URL unreachable (WG down?)."
  notify_failure "reachability" 1 "Could not reach $REST_HEALTH_URL"; exit 1
fi

ping_dms "$PING_URL/start"

# ============================================================================
#  DUMP STAGE  --  native DB dumps into $DUMP_DIR (selected by the config
#  arrays above), plus an optional pre-backup hook as an escape hatch. The dir
#  is added to the backup set and WIPED on exit so plaintext never lingers. Any
#  dump failure aborts the whole run (better no backup than a half-dumped DB).
# ============================================================================
PRE_BACKUP_HOOK="${PRE_BACKUP_HOOK:-$CONFIG_DIR/pre-backup}"   # optional escape hatch
cleanup_dumps() { rm -rf "${DUMP_DIR:?}"/* 2>/dev/null || true; }
if _have_db_config || [[ -x "$PRE_BACKUP_HOOK" ]]; then
  mkdir -p "$DUMP_DIR"; chmod 700 "$DUMP_DIR"
  trap 'cleanup_dumps' EXIT
  cleanup_dumps                       # clear any junk a crashed run left
  __um=$(umask); umask 077            # dumps are 0600
  run_db_dumps
  umask "$__um"
  [[ -x "$PRE_BACKUP_HOOK" ]] && { export DUMP_DIR; run_step "pre-backup-hook" "$PRE_BACKUP_HOOK"; }
  compgen -G "$DUMP_DIR/*.sql" >/dev/null && BACKUP_PATHS+=("$DUMP_DIR")
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

log "Backup complete."
ping_dms "$PING_URL"
