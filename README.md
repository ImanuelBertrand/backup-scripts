# restic backup scripts

Client-side backup tooling for pushing [restic](https://restic.net/) snapshots
from several machines (servers and a laptop) into one central **append-only**
`rest-server`, reachable only over WireGuard.

```
 client hosts                        WireGuard 10.0.0.0/24         backup host (NAS)
 ────────────                        (split tunnel)                ─────────────────
 restic-backup.sh  ──── restic ───────────────────────────────>    rest-server :8000
   config          (rest:http://10.0.0.2:8000/<user>/)             --append-only
   excludes                                                        --private-repos
   pre-backup (optional hook)                                      /data/<user>/
                                                                          │
 ntfy + healthchecks  <──── normal internet ────                   maintenance cron
 (alerts still work when the tunnel is down)                       forget / prune / check
```

**Design in one paragraph.** WireGuard is the transport security, so there is no
TLS, no reverse proxy, and no "am I on trusted Wi-Fi" logic: if `10.0.0.2`
answers, we back up from anywhere; if it doesn't, the tunnel is down and we skip
or alert. Independently of WireGuard, the server enforces `--append-only` (a
compromised client cannot delete its own history) and `--private-repos` (clients
sharing the WG subnet cannot read or delete each other's repos). Retention and
pruning never run on clients — they run locally on the backup host, which is the
only place with delete rights.

## Contents

| File | Where it goes | Purpose |
|---|---|---|
| `restic-backup.sh` | client, e.g. `/usr/local/sbin/` | The entire client. DB dumps → `restic backup`. |
| `config.sample` | client, → `~/.config/restic/config` | Per-host settings **and secrets**. Never commit the filled-in copy. |
| `excludes` | client, → `~/.config/restic/excludes` | Shared exclude patterns. No secrets; committed. |
| `pre-backup` | client, → `~/.config/restic/pre-backup` | **Optional** hook for what the config can't express. Omit if unneeded. |
| `docker-compose.yml` | backup host | The rest-server. |

## Prerequisites

- **restic ≥ 0.16** on every client (for `--retry-lock`). Keep the client version
  **≤** the maintenance host's version — a newer client can write a repo format
  the maintenance host cannot prune.
- `curl` on clients (notifications, reachability probe).
- Docker + Compose on the backup host.
- A working WireGuard tunnel (set up separately — see below).
- Optional: `nmcli` for metered-link detection, `sqlite3` / `mariadb-dump` /
  `pg_dump` for whichever databases you actually dump.

```bash
restic version    # must be >= 0.16
```

---

## 1. Backup host (rest-server)

### 1.1 Directories

Keep auth material **outside** the data directory — the data directory is what
you mirror or copy off-site.

```bash
mkdir -p /share/Backups/restic/data /share/Backups/restic/auth
chmod 700 /share/Backups/restic/data /share/Backups/restic/auth
```

### 1.2 One credential per client

Use bcrypt (`-B`). The username **must equal the first path segment** of that
client's repository URL — this is what `--private-repos` enforces.

```bash
# Fedora/RHEL: dnf install httpd-tools    Debian/Ubuntu: apt install apache2-utils
cd /share/Backups/restic/auth

htpasswd -B -c .htpasswd laptop     # -c CREATES the file (overwrites!) -- first user only
htpasswd -B    .htpasswd srv01      # every subsequent user: NO -c
htpasswd -B    .htpasswd srv02
```

> **`-c` truncates the file.** Use it exactly once. Adding a fourth client later
> with `-c` silently locks out the first three.

### 1.3 Pre-create each client's repo directory

Not strictly required, but it avoids first-run permission surprises:

```bash
mkdir -p /share/Backups/restic/data/{laptop,srv01,srv02}
```

### 1.4 Start it

```bash
docker compose up -d
docker compose logs -f rest-server
```

Sanity check from a client, over the tunnel:

```bash
curl -i http://10.0.0.2:8000/          # 401 is the CORRECT answer -- auth is on
```

A `401` means reachable and authenticating. A timeout means the tunnel is down.
If you get `200` without credentials, `DISABLE_AUTHENTICATION` leaked in
somewhere — stop and fix it before seeding any data.

> **Decide `--private-repos` before seeding.** It fixes every client's repo URL
> to `/<user>/`. Changing it later rewrites every client's URL.

## 2. WireGuard

Configured outside this repo, but one setting matters here: run clients
**split-tunnel**.

```ini
[Peer]
AllowedIPs = 10.0.0.0/24     # NOT 0.0.0.0/0
```

Only backup traffic goes through the tunnel. ntfy and healthchecks keep using
the normal internet, so **alerts still reach you when the tunnel is down** —
which is exactly when you need them.

---

## 3. Client setup

Do this on each machine. A whole-system backup (`BACKUP_PATHS=(/)`) means running
as **root**, so the config lives in `/root/.config/restic/`.

### 3.1 Install

```bash
install -m 755 restic-backup.sh /usr/local/sbin/restic-backup.sh

install -d -m 700 /root/.config/restic
install -m 644 excludes /root/.config/restic/excludes
install -m 600 config.sample /root/.config/restic/config
```

### 3.2 Encryption password

This is what actually protects the data at rest, and it is **separate** from the
rest-server login. Generate one per client:

```bash
openssl rand -base64 32 > /root/.config/restic/encryption-pw
chmod 600 /root/.config/restic/encryption-pw
```

> **Store this somewhere off the machine — a password manager, printed in a
> safe.** If the host dies and this password is gone, its backups are
> permanently unreadable. There is no recovery path. The maintenance host also
> needs a copy (see §6).

### 3.3 Edit the config

Fill in `/root/.config/restic/config`. The minimum:

```bash
export RESTIC_REPOSITORY="rest:http://10.0.0.2:8000/srv01/"
export RESTIC_REST_USERNAME="srv01"          # MUST match the URL path segment
export RESTIC_REST_PASSWORD="…"              # the htpasswd password
export RESTIC_PASSWORD_FILE="/root/.config/restic/encryption-pw"

BACKUP_PATHS=(/)
EXTRA_BACKUP_ARGS=(--one-file-system)        # strongly advised with (/)
```

Then set the per-host behaviour:

| Setting | Servers | Laptop |
|---|---|---|
| `SKIP_IF_METERED` | `"false"` | `"true"` |
| `SKIP_IF_UNREACHABLE` | `"false"` — tunnel down is a failure | see note |
| `EXTRA_BACKUP_ARGS` | `(--one-file-system)` | `(--one-file-system)` |

> **Laptop note.** A silent skip sends **no** healthchecks ping, so the dead-man's
> switch will eventually flag the host as late while you're travelling. Either set
> `SKIP_IF_UNREACHABLE="true"` and give that check a long grace period, or leave
> it `"false"` and accept one failure alert per run whenever the tunnel is down.

Finally, notifications (all optional — leave empty to disable):

```bash
NTFY_URL="https://ntfy.example.com"          # no trailing slash
NTFY_TOPIC_HIGH="backups-high"
NTFY_TOKEN="…"                               # "" if the topic is open
RESTIC_PING_URL="https://hc-ping.com/…"      # healthchecks.io or self-hosted
REST_HEALTH_URL="http://10.0.0.2:8000/"      # reachability probe = "is WG up?"
```

`config` holds three secrets (REST password, ntfy token, ping URL). Keep it
`0600` and **never commit it** — commit only `config.sample`.

### 3.4 Initialise the repository (once per client)

```bash
set -a; . /root/.config/restic/config; set +a
restic init
```

Expect `created restic repository … at rest:http://10.0.0.2:8000/srv01/`. A
`401` here means `RESTIC_REST_USERNAME` doesn't match the URL path segment.

### 3.5 First run

```bash
RESTIC_CONFIG_DIR=/root/.config/restic /usr/local/sbin/restic-backup.sh
```

Success is **silent by design** — no ntfy on success. You should see
`Backup complete.` and a new snapshot:

```bash
restic snapshots
```

---

## 4. Scheduling

`/etc/systemd/system/restic-backup.service`:

```ini
[Unit]
Description=restic backup to rest-server
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
Environment=RESTIC_CONFIG_DIR=/root/.config/restic
ExecStart=/usr/local/sbin/restic-backup.sh
Nice=10
IOSchedulingClass=idle
```

`/etc/systemd/system/restic-backup.timer`:

```ini
[Unit]
Description=Daily restic backup

[Timer]
OnCalendar=daily
RandomizedDelaySec=30m
Persistent=true          # laptops: catches runs missed while suspended/off

[Install]
WantedBy=timers.target
```

```bash
systemctl daemon-reload
systemctl enable --now restic-backup.timer
systemctl list-timers restic-backup.timer
journalctl -u restic-backup.service -f
```

`RandomizedDelaySec` staggers clients so they don't collide on the repo lock.
The script also takes a `flock` on `$CONFIG_DIR/.lock`, so overlapping runs on
one host exit cleanly rather than piling up.

---

## 5. Databases

Databases are dumped **before** the snapshot, into `$DUMP_DIR`
(`~/.config/restic/db-dumps`), which is added to the backup set and **wiped on
exit** so plaintext never lingers. Any dump failure aborts the whole run —
better no backup than a backup containing a half-dumped database.

Live MariaDB data files are excluded (`/var/lib/mysql` in `excludes`) precisely
because the dump is the consistent source of truth.

### 5.1 Declarative (the normal case)

Set the arrays in `config`. Nothing else to install.

```bash
MARIADB_LOCAL=(ALL)                  # or (appdb wordpress) for one file per DB
POSTGRES_LOCAL=(analytics)           # or (ALL)
DOCKER_AUTO=(app-mariadb pg-01)      # name the CONTAINER only
SQLITE_FILES=(vaultwarden:/srv/vaultwarden/data/db.sqlite3)
```

`ALL` produces one combined dump (`--all-databases` / `pg_dumpall`); naming
databases produces one file each, which dedups better and restores individually.

`DOCKER_AUTO` detects the engine **inside** the container, dumps everything, and
takes the password from that container's own environment
(`MARIADB_ROOT_PASSWORD` / `MYSQL_ROOT_PASSWORD` / `POSTGRES_PASSWORD`) — so it
never appears in the host process list. List candidates with:

```bash
docker ps --format '{{.Names}}\t{{.Image}}'
```

Local MariaDB uses `~/.my.cnf`; local PostgreSQL uses `sudo -n -u postgres`
(peer auth, `-n` so it fails fast under cron instead of hanging on a prompt).

### 5.2 The `pre-backup` hook (escape hatch)

Only for what the arrays can't express — container-only SQLite, a DB password
kept in a host secret file, quiescing a service, a non-DB export. Install it and
**make it executable**, or it's skipped:

```bash
install -m 700 pre-backup /root/.config/restic/pre-backup
```

Edit the `WHAT TO PREPARE` block; the file ships empty with commented examples.
The contract: write into `$DUMP_DIR`, exit non-zero on any failure, and **do not
clean `$DUMP_DIR`** — the main script owns it and runs the hook *after* the
native dumps.

Test standalone:

```bash
DUMP_DIR=/tmp/dumptest /root/.config/restic/pre-backup && ls -l /tmp/dumptest
```

### 5.3 Verify a dump is actually usable

Do this once per database, and after any change. A dump you have never restored
is a hypothesis:

```bash
restic dump latest /root/.config/restic/db-dumps/mariadb-all.sql | head -50
```

---

## 6. Maintenance host (retention, prune, check)

Clients **cannot** delete anything — that's the point of `--append-only`. So
retention runs on the backup host as *local* restic, directly against each
subrepo, bypassing rest-server entirely.

This is not shipped in this repo. A starting point, as a daily cron:

```bash
#!/bin/bash
set -euo pipefail
for repo in /share/Backups/restic/data/*/; do
  user=$(basename "$repo")
  export RESTIC_REPOSITORY="$repo"
  export RESTIC_PASSWORD_FILE="/root/.restic-pw/$user"
  restic forget --keep-daily 14 --keep-weekly 8 --keep-monthly 12 --keep-yearly 3 --prune
  restic check
done
```

Three things to be deliberate about:

- **This host can decrypt everything.** It needs every client's encryption
  password. Treat it as being as sensitive as all the clients combined; `0600`,
  root-only, ideally on encrypted storage.
- **Prune takes the repo lock.** Clients wait `LOCK_WAIT` (default 15m) via
  `--retry-lock`, so schedule maintenance well away from client backup windows.
- **`restic check` doesn't read the data** by default. Periodically run
  `restic check --read-data-subset=5%` to catch bit-rot; a full `--read-data`
  occasionally if the repo size allows.

Off-site: mirror `/share/Backups/restic/data` (it's encrypted at rest, so a dumb
file copy is fine), or use `restic copy` to a second repo.

---

## 7. Restore

```bash
set -a; . /root/.config/restic/config; set +a

restic snapshots                                  # find the one you want
restic restore latest --target /mnt/restore       # everything
restic restore <id> --target /mnt/restore --include /etc/nginx    # one path
restic dump <id> /path/to/file.txt > file.txt     # a single file to stdout
restic mount /mnt/browse                          # browse snapshots as a filesystem
```

Restoring a database means restoring its dump from `db-dumps/` and feeding it
back in (`mariadb < dump.sql`, `psql -f dump.sql`), **not** copying
`/var/lib/mysql` — which isn't in the backup anyway.

**Restore from a client you no longer have?** All you need is the repo URL, the
rest-server credentials, and the encryption password. Any machine on the tunnel
can read a repo given those three, which is why §3.2 matters.

---

## 8. Monitoring

| Channel | When | Notes |
|---|---|---|
| ntfy (`urgent`) | Failure only | Success is intentionally silent. |
| healthchecks ping | `/start`, success, `/fail` | Catches the case where the script never runs at all. |
| `notify-send` | Failure, desktop only | Best-effort. |

Test the alerting path deliberately — point `RESTIC_REPOSITORY` at a bogus URL
and confirm the ntfy message and `/fail` ping actually arrive. Silent-on-success
monitoring is only as good as the last time you proved the alarm works.

---

## 9. Troubleshooting

| Symptom | Cause |
|---|---|
| `401 Unauthorized` | `RESTIC_REST_USERNAME` ≠ first path segment of the repo URL (`--private-repos`), or wrong htpasswd password. |
| Timeout / `unreachable` | WireGuard down. `wg show`, then `curl -i http://10.0.0.2:8000/`. |
| `repository is already locked` | Concurrent maintenance prune. Clients retry for `LOCK_WAIT`; raise it or move the maintenance window. |
| `Another run holds the lock; exiting.` | A previous run is still going (`flock`). Not an error. |
| Backup skipped, no alert | Metered link, or `SKIP_IF_UNREACHABLE="true"`. By design; no ping is sent. |
| Dump fails, whole backup aborts | Intended. Fix the dump — don't disable the check. |
| `no mariadb-dump/pg_dumpall in container` | `DOCKER_AUTO` on a SQLite container. Use `SQLITE_FILES` with the host path, or the hook. |
| Alert fires but no desktop popup | `notify-send` from a root systemd unit can't reach your session. The ntfy message is the real channel. |
| Exclude pattern silently ignored | restic treats `#` as a comment **only** at the start of a line. An inline comment becomes part of the pattern. |

---

## Security model

| Control | Protects against |
|---|---|
| WireGuard | Anything on the public internet; provides encryption + peer auth for the hop. |
| `--append-only` | A compromised but validly-authenticated client deleting its own history (ransomware). |
| `--private-repos` + per-client htpasswd | Clients on the same WG subnet reading or deleting each other's backups. |
| Per-client encryption password | The backup host's storage being read or stolen. |
| `:ro` auth mount, `no-new-privileges` | A compromised rest-server container rewriting credentials or escalating. |
| `$DUMP_DIR` wiped on exit, mode `0700` | Plaintext database dumps lingering on client disks. |
| Secrets via env / container env, never argv | Passwords appearing in the host process list. |

Not covered: the maintenance host is a single point of trust — it holds every
encryption password and has delete rights on every repo. If that matters for
your threat model, split retention per client or keep an off-site copy the
maintenance host cannot reach.

If you ever keep a filled-in `config` inside a git repo, add a `.gitignore` with
`config` and `encryption-pw` first — or better, keep them out of git entirely.
