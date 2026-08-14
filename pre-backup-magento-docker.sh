#!/bin/bash
# pre-backup-magento-docker.sh -- database dumps for the restic backup on a host
# whose only database is a Magento 2 MariaDB running in a docker container.
#
# CONTRACT WITH restic-backup.sh
#   - Reads $DUMP_DIR from the environment (the main script exports it).
#   - Writes ONE uncompressed .sql file there (uncompressed -> restic dedups
#     well; the main script wipes $DUMP_DIR on exit, so plaintext never lingers).
#   - Exits non-zero if anything fails, so the main script aborts the whole run
#     and alerts. Better no backup than a half-dumped database.
#
# INSTALL
#   cp pre-backup-magento-docker.sh ~/.config/restic/pre-backup && chmod 700 ...
#   (or point PRE_BACKUP_HOOK at it in the config)
#
#   This hook composes with the declarative dump arrays: the main script empties
#   $DUMP_DIR, runs run_db_dumps, and only then calls us, so anything DOCKER_AUTO
#   / MARIADB_LOCAL / ... produced is still there and is left alone. Normally the
#   Magento container is handled here INSTEAD of via DOCKER_AUTO (that path uses
#   --all-databases and hits the error-1412 problem described below), so keep it
#   out of DOCKER_AUTO -- but other databases on the host can stay declarative.
#
# WHY THIS EXISTS
#   Magento's indexers build into *_replica tables and swap them in with
#   RENAME TABLE. That DDL invalidates mariadb-dump's --single-transaction
#   snapshot mid-dump:
#     Error 1412: Table definition has changed, please retry transaction
#   Those tables are derived data. This script dumps the SCHEMA of everything
#   and the DATA of everything except the volatile index tables.
#
#   >> RESTORE: after importing, run `bin/magento indexer:reindex`. The index
#      tables come back empty by design. <<
#
# CREDENTIALS
#   Never handled on the host. The dump commands run inside the container and
#   read the container's own MARIADB_ROOT_PASSWORD / MYSQL_ROOT_PASSWORD (or the
#   *_FILE secret variant). Nothing appears in the host process list.
#
# Standalone test:
#   DUMP_DIR=/tmp/dumptest ./pre-backup-magento-docker.sh && ls -l /tmp/dumptest
# ============================================================================
set -euo pipefail
umask 077                                   # dumps are plaintext -> 0600 only
export PATH="/usr/local/bin:/usr/bin:/bin:${PATH:-}"

DUMP_DIR="${DUMP_DIR:-$HOME/.config/restic/db-dumps}"
mkdir -p "$DUMP_DIR"; chmod 700 "$DUMP_DIR"

# Both go to STDERR on purpose: several helpers below are read via $( ), and a
# log line on stdout would end up inside the captured value (or inside a dump).
# The main script's run_step captures stdout and stderr together anyway.
log() { printf '%s pre-backup: %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

# Only our own half-written temp files -- NEVER *.sql. The main script already
# emptied $DUMP_DIR before the native dump stage, so there is nothing stale to
# clean here, and wiping *.sql would silently delete the dumps run_db_dumps just
# produced (no error, just a database missing from the snapshot).
trap 'rm -f "${DUMP_DIR:?}"/*.tmp 2>/dev/null || true' EXIT

slug() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }

# dump_to <name> <command...> -- stdout of the command lands atomically in
# $DUMP_DIR/<name>.sql. stderr flows to ours and is captured by the main script.
#
# NOTE for anything called through here: the `|| die` below suppresses errexit
# inside the called function's whole body, so those functions must check every
# command explicitly (`|| return 1`). Otherwise a failed second pass yields a
# schema-only file that still passes the non-empty test.
dump_to() {
  local name; name="$(slug "$1")"; shift
  local out="$DUMP_DIR/$name.sql" tmp="$DUMP_DIR/$name.sql.tmp"
  log "dumping -> $name.sql"
  "$@" >"$tmp" || die "dump '$name' failed (exit $?)"
  [[ -s "$tmp" ]] || die "dump '$name' produced an empty file"
  mv -f "$tmp" "$out"
}

# ============================================================================
# HELPERS
# ============================================================================

# Run a mariadb tool INSIDE the container as root, credentials from the
# container's own environment. No `-t`: a TTY would turn \n into \r\n and
# corrupt the dump. MYSQL_PWD instead of -p keeps the password out of the
# container's process list too.
dexec_mariadb() {                        # dexec_mariadb <container> <tool> [args...]
  local cont="$1" tool="$2"; shift 2
  docker exec "$cont" sh -c '
    tool="$1"; shift
    : "${MARIADB_ROOT_PASSWORD:=${MYSQL_ROOT_PASSWORD:-}}"
    if [ -z "$MARIADB_ROOT_PASSWORD" ]; then
      f="${MARIADB_ROOT_PASSWORD_FILE:-${MYSQL_ROOT_PASSWORD_FILE:-}}"
      [ -n "$f" ] && [ -r "$f" ] && MARIADB_ROOT_PASSWORD="$(cat "$f")"
    fi
    [ -n "$MARIADB_ROOT_PASSWORD" ] && export MYSQL_PWD="$MARIADB_ROOT_PASSWORD"
    exec "$tool" -uroot "$@"
  ' _ "$tool" "$@"
}

require_container() {
  local cont="$1"
  command -v docker >/dev/null 2>&1 || die "docker not found in PATH"
  docker inspect -f '{{.State.Running}}' "$cont" 2>/dev/null | grep -qx true \
    || die "container '$cont' is not running"
}

# Sole user database in the container, if the caller didn't name one.
# Prints the name on stdout. `die` here runs in a command substitution, so it
# only kills the subshell -- the caller MUST use `|| exit 1`.
detect_single_db() {                     # detect_single_db <container>
  local cont="$1" raw dbs=()
  raw="$(dexec_mariadb "$cont" mariadb -N -B -e "SHOW DATABASES" | tr -d '\r')" \
    || die "could not list databases in '$cont' (credentials? see the *_PASSWORD env of the container)"
  mapfile -t dbs < <(printf '%s\n' "$raw" \
                     | grep -Ev '^(information_schema|performance_schema|mysql|sys)$' \
                     | grep -v '^$')
  (( ${#dbs[@]} == 1 )) \
    || die "expected exactly one user database in '$cont', found ${#dbs[@]}: ${dbs[*]:-none}. Name it explicitly at the bottom of this script."
  printf '%s' "${dbs[0]}"
}

# The volatile tables: Magento rebuilds all of these with indexer:reindex.
# Adjust to your installation -- verify with the self-check below, a count of 0
# means the dump would still hit error 1412.
magento_ignore_list() {                  # magento_ignore_list <container> <db>
  local cont="$1" db="$2"
  dexec_mariadb "$cont" mariadb -N -B -e "
    SELECT CONCAT('--ignore-table=$db.', table_name)
      FROM information_schema.tables
     WHERE table_schema = '$db'
       AND (    table_name LIKE '%\\_replica'
             OR table_name LIKE '%\\_idx'
             OR table_name LIKE '%\\_tmp'
             OR table_name LIKE 'catalog\\_%\\_index\\_%'
             OR table_name LIKE 'catalogsearch\\_fulltext%'
             OR table_name LIKE 'inventory\\_%\\_index%'
             OR table_name IN ('session','report_event') )
     ORDER BY table_name" | tr -d '\r'
}

# Two passes on stdout: schema for everything, then data minus the volatile
# tables. They are separate snapshots a second apart -- harmless for Magento,
# which does no DDL outside the index swaps.
magento_dump() {                         # magento_dump <container> <db>
  local cont="$1" db="$2" list ignore=()

  list="$(magento_ignore_list "$cont" "$db")" || return 1
  [[ -n "$list" ]] && mapfile -t ignore <<<"$list"
  log "magento: skipping data of ${#ignore[@]} volatile tables in '$db'"
  (( ${#ignore[@]} )) || log "WARN: no volatile tables matched -- check the LIKE patterns and the db name"

  # pass 1: CREATE statements for ALL tables, plus routines, events, triggers
  dexec_mariadb "$cont" mariadb-dump --single-transaction --quick \
      --routines --events --no-data --databases "$db" || return 1

  # pass 2: data only; triggers already emitted above, so skip them here
  dexec_mariadb "$cont" mariadb-dump --single-transaction --quick \
      --no-create-info --skip-triggers \
      "${ignore[@]+"${ignore[@]}"}" "$db" || return 1
}

dump_magento_docker() {                  # dump_magento_docker <container> [db]
  local cont="$1" db="${2:-}"
  require_container "$cont"
  if [[ -z "$db" ]]; then
    db="$(detect_single_db "$cont")" || exit 1   # die() only exits the subshell
    log "auto-detected database '$db'"
  fi
  dump_to "mariadb@$cont-$db" magento_dump "$cont" "$db"
}

# ============================================================================
# WHAT TO DUMP -- the only part you edit
# ============================================================================

dump_magento_docker sarto-m2-db-1

# Optional: grants / hand-made DB users. The old DOCKER_AUTO used
# --all-databases, which included these; naming one database drops them. For a
# compose-managed container the credentials are recreated from the environment
# on first start, so this is usually unnecessary. Restoring it needs FLUSH
# PRIVILEGES and the same MariaDB major version.
#
# dump_to "mariadb@sarto-m2-db-1-mysql" \
#   dexec_mariadb sarto-m2-db-1 mariadb-dump --single-transaction --quick --databases mysql

log "all dumps complete."
