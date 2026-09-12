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
   excludes.local (optional, per host)                             /data/<user>/
   pre-backup (optional hook)
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
only place with delete rights. Cron invokes the client script **hourly** and the
script decides for itself whether this hour is the moment (§4); a skip is always
silent, and what turns silence into an alert is the **age of the last successful
backup**, not the reason for the skip.

## Contents

| File | Where it goes | Purpose |
|---|---|---|
| `restic-backup.sh` | client, e.g. `/usr/local/sbin/` | The entire client. DB dumps → `restic backup`. |
| `config.sample` | client, → `~/.config/restic/config` | Per-host settings **and secrets**. Never commit the filled-in copy. |
| `excludes` | client, → `~/.config/restic/excludes` | Fleet-wide exclude patterns. No secrets; committed. **Overwritten by every deploy** — never hand-edit on a host. |
| `excludes.local.sample` | client, → `~/.config/restic/excludes.local` | **Optional**, per host, hand-managed. Read *after* `excludes`, so it adds patterns or takes one back with `!`. |
| `pre-backup` | client, → `~/.config/restic/pre-backup` | **Optional** hook for what the config can't express. Omit if unneeded. |
| `restic-backup.cron` | client, → `/etc/cron.d/restic-backup` | Hourly invocation. The **script** decides when to actually run. |
| `deploy.sh` | admin machine (stays in the repo) | Pushes the files above to every host. Clients never pull. |
| `deploy.conf.sample` | admin machine, → `~/.config/restic/deploy.conf` | Your host list, paths, and per-host cron minute. Lives outside the checkout. |
| `docker-compose.yml` | backup host | The rest-server. |
| `restic-maintenance.sh` | maintenance host, e.g. `/usr/local/sbin/` | Retention, prune, check and a restore smoke-test. Never runs on a client. |
| `maintenance.config.sample` | maintenance host, → `~/.config/restic-maintenance/config` | Its settings **and secrets**. Hand-managed; `deploy.sh` never touches it. |

## Prerequisites

- **restic ≥ 0.16** on every client (for `--retry-lock`). Keep the client version
  **≤** the maintenance host's version — a newer client can write a repo format
  the maintenance host cannot prune.
- `curl` on clients (notifications, reachability probe).
- `cron` on clients (`cronie` on Fedora/RHEL). No systemd timers are used.
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

The published port is bound to `10.0.0.2:8000` — this host's address *inside the
tunnel* — and not to `0.0.0.0`. Change it to match your own WireGuard address.
Docker inserts its port-forwarding rules ahead of the firewalld/ufw `INPUT`
chain, so a plain `"8000:8000"` listens on every interface including public ones
and your firewall rules never see the traffic. Since there is deliberately no TLS
here, that would mean HTTP Basic auth in cleartext on the open internet.

Sanity check from a client, over the tunnel:

```bash
curl -i http://10.0.0.2:8000/          # 401 is the CORRECT answer -- auth is on
```

A `401` means reachable and authenticating. A timeout means the tunnel is down.
If you get `200` without credentials, `DISABLE_AUTHENTICATION` leaked in
somewhere — stop and fix it before seeding any data. From a machine *outside*
the tunnel the same request should time out; if it answers, the bind address is
wrong.

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

### 2.1 Self-heal: bouncing a tunnel that is up but dead

If the reachability probe fails and `WG_INTERFACE` is set, the script bounces the
tunnel and probes again. This targets the tunnel that is "up" but dead: the
peer's endpoint moved (dynamic DNS, a new NAT mapping) and the kernel goes on
talking to the old address indefinitely. Split-tunnel `AllowedIPs = 10.0.0.0/24`
keeps the blast radius at zero — bouncing the interface cannot drop your SSH
session.

Four guards worth knowing about:

- It prefers `systemctl restart wg-quick@<if>` whenever that unit is active, and
  only falls back to `wg-quick down/up`. Running `wg-quick` behind systemd's back
  leaves the unit convinced the interface is still up.
- With **no default route** it does not touch the tunnel at all. The host is
  simply offline; `wg-quick up` could not resolve the endpoint anyway, and a
  failed `up` after a successful `down` leaves you worse off than before.
- **At most one bounce per `WG_BOUNCE_INTERVAL_HOURS`** (default `6`, `0` to
  disable the limit). Cron calls the script hourly and past `FORCE_AFTER_HOURS`
  every one of those runs is due, so a backend that is genuinely down for two
  days would otherwise be met with 48 restarts. The *first* bounce of an outage
  is still immediate — only the retries are spaced — and a successful backup
  resets the interval.
- If something else owns the tunnel (NetworkManager, a bespoke unit), set
  `WG_RESTART_CMD` and it runs in place of the `systemctl` / `wg-quick` logic
  above. It does **not** opt out of the other two guards: the default-route
  check and the bounce interval are both evaluated before either path runs.
  A custom restart command is no better able to resolve an endpoint on a host
  with no route than the built-in one is.

A host that needs a nightly bounce has a different problem underneath (endpoint
DNS TTL, or a NAT timeout shorter than `PersistentKeepalive`). Grep the log for
`WG:` occasionally rather than letting the self-heal paper over it forever.

---

## 3. Client setup

Do this on each machine. A whole-system backup (`BACKUP_PATHS=(/)`) means running
as **root**, so the config lives in `/root/.config/restic/`.

### 3.1 Install

```bash
install -m 755 restic-backup.sh /usr/local/sbin/restic-backup.sh

install -d -m 700 /root/.config/restic
install -m 644 excludes /root/.config/restic/excludes
# optional, only if this host needs its own patterns:
# install -m 644 excludes.local.sample /root/.config/restic/excludes.local
install -m 600 config.sample /root/.config/restic/config
```

The modes above are not cosmetic. `config` and the optional `pre-backup` hook are
*executed* as root on every run, so the script refuses to start unless each one —
and every directory on the way to it — is owned by root (or by the user running
it) and not writable by group or other. If you move `CONFIG_DIR` somewhere else,
carry the `700` with it.

### 3.2 Encryption password

This is what actually protects the data at rest, and it is **separate** from the
rest-server login. Generate one per client:

```bash
( umask 077; openssl rand -base64 32 > /root/.config/restic/encryption-pw )
```

(The `umask` is not decoration: `> file` creates it under root's default 022,
so writing first and `chmod`-ing after leaves the password world-readable in
between — and permanently so if only the first line gets pasted.)

> **Store this somewhere off the machine — a password manager, printed in a
> safe.** If the host dies and this password is gone, its backups are
> permanently unreadable. There is no recovery path. The maintenance host also
> needs a copy (see §6).

`encryption-pw` and `config` are excluded by `restic-backup.sh` itself, derived
from `CONFIG_DIR`, so a `(/)` backup does not contain them. A password inside the repository it unlocks cannot help you — you
need it to read the snapshot in the first place — while it does mean that one
leaked client password yields that host's rest-server credentials and ntfy token
as well, and that every retired password stays readable for as long as an old
snapshot survives. `$DUMP_DIR` sits in the same directory and *is* backed up;
the two files are named individually for that reason. Building the paths from
`CONFIG_DIR` keeps them correct wherever it points — a literal path in
`excludes` would be right for one `CONFIG_DIR` only, and on a host that set a
different one the password would go into the repository it unlocks, silently.
Neither `excludes` nor `excludes.local` can drop them, and re-including either
with a `!` pattern is refused at preflight.

### 3.3 Edit the config

Fill in `/root/.config/restic/config`. The minimum:

```bash
export RESTIC_REPOSITORY="rest:http://10.0.0.2:8000/srv01/"
export RESTIC_REST_USERNAME="srv01"          # MUST match the URL path segment
export RESTIC_REST_PASSWORD="…"              # the htpasswd password
export RESTIC_PASSWORD_FILE="/root/.config/restic/encryption-pw"

BACKUP_PATHS=(/)
EXTRA_BACKUP_ARGS=(--one-file-system)        # see the caveat below
UNBACKED_MOUNTS=()                           # mounts you chose not to back up
```

> **`--one-file-system` does not warn you about what it skips.** It is the right
> flag for keeping restic out of a USB disk, and it stops just as quietly at
> `/home`, `/var` or `/srv` when those are separate logical volumes — the normal
> LVM and cloud-image layout. The snapshot then contains the root filesystem and
> nothing else, exits `0`, and looks like every healthy backup until a restore.
>
> The script therefore names every mounted filesystem inside `BACKUP_PATHS`
> that the flag is skipping, and pages about it at urgent priority — once when
> the set appears, again whenever it changes, then at most every
> `NOTIFY_REPEAT_HOURS`. The backup still runs: a snapshot missing one mount is
> worth more than the no-snapshot-at-all that refusing would produce on every
> hourly run until someone edited the config on that host. The fix is to add it
> to `BACKUP_PATHS`, exclude it, or list it in `UNBACKED_MOUNTS` to say the
> omission is deliberate. Pseudo-filesystems and bind mounts within the same
> filesystem are not reported — restic crosses the latter regardless, because
> `--one-file-system` compares device ids.
>
> A source path that exists but is **empty and not a mountpoint** is refused for
> the same reason: that is exactly what a filesystem that failed to mount looks
> like, and it would otherwise be snapshotted as a successful, empty backup.

Then set the per-host behaviour:

| Setting | Servers | Laptop |
|---|---|---|
| `SKIP_IF_METERED` | `"false"` | `"true"` |
| `MAX_BACKUP_AGE_HOURS` | `"36"` — one missed night is fine, two is not | `"168"` — a week away from the tunnel is normal |
| `BACKUP_WINDOW` | `"23-06"` | `"23-06"` (rarely satisfied — see note) |
| `WG_INTERFACE` | `"wg0"` if the tunnel is local to this host | `"wg0"` |
| `WG_BOUNCE_INTERVAL_HOURS` | `"6"` (default) | `"6"` (default) |
| `EXTRA_BACKUP_ARGS` | `(--one-file-system)` | `(--one-file-system)` |

> **Why there is no "skip quietly" switch.** An unreachable backend is *always*
> a silent skip, and `MAX_BACKUP_AGE_HOURS` decides when a run of silent skips
> becomes a failure. A boolean cannot express that: "always skip" leaves a
> laptop whose tunnel broke a week ago saying nothing at all, and "never skip"
> has a server saying something every single run. A config still setting
> `SKIP_IF_UNREACHABLE` gets a warning, and the variable is ignored.

> **Laptop note.** A laptop asleep from 23:00 to 06:00 never satisfies
> `BACKUP_WINDOW`, so every one of its backups comes from the
> `FORCE_AFTER_HOURS` catch-up, at whatever daytime hour it happens to be awake.
> That is intended. What the laptop gains from the hourly schedule is *retries* —
> 24 chances a day to catch a moment when the tunnel is up, instead of one.

Finally, notifications (all optional — leave empty to disable):

```bash
NTFY_URL="https://ntfy.example.com"          # no trailing slash
NTFY_TOPIC_HIGH="backups-high"
NTFY_TOKEN="…"                               # "" if the topic is open
RESTIC_PING_URL="https://hc-ping.com/…"      # healthchecks.io or self-hosted
REST_HEALTH_URL="http://10.0.0.2:8000/"      # reachability probe = "is WG up?"
WG_INTERFACE="wg0"                           # "" to never touch the tunnel
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
RESTIC_CONFIG_DIR=/root/.config/restic /usr/local/sbin/restic-backup.sh --force
```

`--force` bypasses the window and the min-interval gates, which a first run by
hand will otherwise trip (§4). Success is **silent by design** — no ntfy on
success. You should see `Backup complete.` and a new snapshot:

```bash
restic snapshots
```

---

## 4. Scheduling

**Cron calls the script every hour. The script decides whether to back up.**

All the policy lives in the config (§3.3), not in the crontab: one line per host,
identical everywhere, and you change behaviour by editing a file instead of a
schedule. A run that isn't due exits in milliseconds.

### 4.1 Install the cron entry

```bash
install -m 755 restic-backup.sh /usr/local/sbin/restic-backup.sh
install -m 644 restic-backup.cron /etc/cron.d/restic-backup      # NOTE: no .cron suffix
```

```
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
MAILTO=""
RESTIC_CONFIG_DIR=/root/.config/restic

# m  h dom mon dow  user  command
  23 * *   *   *    root  nice -n10 ionice -c3 /usr/local/sbin/restic-backup.sh 2>&1 | logger -t restic-backup
```

Five details in there, each fixing something specific to cron:

| Detail | Why |
|---|---|
| filename with **no dot** | cronie *silently* ignores `/etc/cron.d` entries whose names contain a `.`. Install as `restic-backup`, not `restic-backup.cron`. Confirm with `systemctl reload crond && journalctl -u crond \| tail`. |
| `MAILTO=""` + `logger` | `run_step` prints every stage's output. Under cron that goes to root's mail — at hourly invocation that is 24 mails per host per day, and the *silent* skips mail too. Send the lot to syslog; ntfy and healthchecks are the real alert channels. |
| `RESTIC_CONFIG_DIR=` | The script falls back to `$HOME/.config/restic`, and `$HOME` under cron is not reliably `/root` across anacron / crontab / `cron.d`. Pin it. |
| `nice` / `ionice` | `/etc/cron.daily` inherits `nice` from `/etc/anacrontab`; `/etc/cron.d` does not. Without this a whole-`/` backup is noticeably rude on a laptop. `ionice -c3` matters more than the nice level. |
| a **different minute per host** | Staggers clients off the repo lock. Unlike a random delay you can see the whole fleet's spread at a glance, and reproduce it. |

### 4.2 What the script does with those 24 invocations

```
BACKUP_WINDOW="23-06"        run in this local-hour window, ...
MIN_INTERVAL_HOURS="20"      ... but not if a run succeeded this recently, ...
FORCE_AFTER_HOURS="24"       ... and ignore the window entirely past this age.
MAX_BACKUP_AGE_HOURS="36"    hard fail: alert once the last success is this old.
```

On a server this produces one backup a night at ~23:00, with six more chances
before 06:00 if the first attempt finds the tunnel down.

`MIN_INTERVAL_HOURS` must stay **below 24**. At exactly 24, a run that lands at
01:00 makes the next one eligible at 01:00, and that ratchet walks the backup
later every day until it falls out of the window entirely.

> **`FORCE_AFTER_HOURS` is the only catch-up you have.** Plain cron does not
> replay jobs missed while a machine was off or asleep — no anacron, no systemd
> `Persistent=`. That makes `/root/.config/restic/.last-success` load-bearing: it
> is the sole record of when a backup last worked, it is written **only** after
> `restic backup` returns 0, and nothing else touches it. Deleting it makes the
> host back up on its next invocation (harmless); a stale copy restored from a
> snapshot would make it skip (which is why `MAX_BACKUP_AGE_HOURS` exists).

### 4.3 A skip cannot hide

Every path that declines to back up — not due, metered link, tunnel down —
exits through the same staleness check. If the last success is older than
`MAX_BACKUP_AGE_HOURS` the script pages you and exits `1`, whatever the reason
for the skip.

The one exception is losing the `flock` to a still-running backup, because
there the age of the last success describes the *holder*, which has not
finished yet — on a laptop catching up after a week offline it is a week old
while the run in progress is perfectly healthy. That skip is judged by how
long the lock has been held instead: quiet below `MAX_BACKUP_AGE_HOURS`, and
a page above it, where the holder is not slow but wedged.

This is what makes silent skipping safe: a host that quietly stops backing up
alerts **locally**, without waiting on the external dead-man's switch.

Because 24 invocations a day must not mean 24 pushes, notification is throttled:

| Event | Notification |
|---|---|
| First failure after a success | ntfy **urgent** — breakage is actionable now |
| Further failures, still under `MAX_BACKUP_AGE_HOURS` | log + `/fail` ping only |
| Crossing `MAX_BACKUP_AGE_HOURS` | ntfy **urgent** (escalation) |
| Still stale after that | ntfy at most every `NOTIFY_REPEAT_HOURS` |
| A successful backup | nothing — and the streak resets, so the next failure pages again |

State lives in `$CONFIG_DIR/.notify-state` and is deleted on every success.

A failure *before* the config is loaded — a file that will not parse, wrong
ownership, a missing `BACKUP_PATHS` — is reported the same way. The ntfy and
ping settings needed to say so are read out of the config as plain text, without
executing it, so a config broken by an interrupted edit still pages instead of
dying into `logger` with `MAILTO=""` and taking the staleness alarm with it.
These count as hard failures from the first occurrence (a broken config does not
heal itself) but go through the same throttle, so it is one page, then
`NOTIFY_REPEAT_HOURS`.

### 4.4 Inspect the decision

`--status` prints what the script would do, and alerts nobody:

```console
# restic-backup.sh --status
last success : 2026-09-11 23:24:07 (6h29m ago)
window       : 23-06  (now 05:53 -> inside)
thresholds   : min-interval 20h, catch-up 24h, hard-fail 36h
stale        : no
mounts       : all mounts covered
version      : matches published (checked 3h12m ago)
decision     : not due, would skip
```

It sends no notification and consumes none of the alerting state — the one
thing it does write is `.first-seen`, which starts the staleness clock on a host
that has never backed up, and without which a host whose cron never fires would
report healthy forever. It reports through its exit code, so it works as a
health probe on its own:

| Exit | Meaning |
|-----:|---------|
| `0`  | healthy |
| `3`  | no successful backup within `MAX_BACKUP_AGE_HOURS` (`stale: YES`) |
| `1`  | cannot tell — missing, untrusted or unparseable config |

```bash
journalctl -t restic-backup -n 50        # what cron actually ran
journalctl -t restic-backup | grep 'WG:' # tunnel restarts (see 2.1)
restic-backup.sh --force                 # run now, ignoring every gate
restic-backup.sh --check-update          # am I running the published version? (§10)
```

### 4.5 Migrating from a daily cron job

If a host already runs restic once a day — from `/etc/cron.daily`, or a classic
crontab entry — replace that trigger rather than adding to it.

```bash
# 1. seed the stamp with a known-good run, so the new schedule starts from a
#    real success instead of backing the whole fleet up at once on deploy
install -m 755 restic-backup.sh /usr/local/sbin/restic-backup.sh
/usr/local/sbin/restic-backup.sh --force

# 2. remove the old triggers -- whichever of these the host actually has
rm -f /etc/cron.daily/restic-backup*
crontab -l | grep -v restic-backup | crontab -   # check the output first!

# 3. install the hourly entry, with a minute unique to this host
install -m 644 restic-backup.cron /etc/cron.d/restic-backup
$EDITOR /etc/cron.d/restic-backup

# 4. confirm
/usr/local/sbin/restic-backup.sh --status
```

Then set `MAX_BACKUP_AGE_HOURS` in each config (§3.3): it is what turns a run
of silent skips into an alert, and it has no useful default for a host whose
schedule you have just changed.

> **Leaving `/etc/cron.daily` costs you anacron's catch-up**, which on most
> distributions is what backs a machine up after every boot. `FORCE_AFTER_HOURS`
> replaces it — which is why it is worth running the new script on the old
> schedule for a few days first, and checking `--status` reports a sane
> `last success`, before you pull the anacron entry.

> **Retune the healthchecks grace period** to sit above `MAX_BACKUP_AGE_HOURS`
> (48h for a 36h server). The local staleness check is now the fast alarm; the
> external dead-man's switch is there for the case the whole host is dead and
> cannot alert about anything. Two alarms at the same threshold just means two
> pushes for one event.

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
retention runs on the backup host, through a **second** rest-server: LAN-only,
delete-capable, and behind its own htpasswd file, so a leaked client backup
credential cannot authenticate against it.

`restic-maintenance.sh` in this repo is what runs there, daily from cron. Per
client, in order:

```
unlock → forget → prune → check → restore smoke-test
```

`check` and the restore test run every time. `forget` and `prune` run only when
that client's last successful prune is older than `PRUNE_MIN_INTERVAL_DAYS`:
prune is the expensive step — repacking touches every partially-used pack file
— so each client carries its own timestamp under `$CONFIG_DIR/state/` and comes
due independently, rather than every repo landing on the same night. `--prune`
forces it for every client in one run.

`check` runs *after* prune deliberately: prune is the one step that rewrites
pack files, so verifying behind it catches a bad repack in the run that caused
it. The restore smoke-test then pulls one small known file out of `latest` and
asserts it materialised — `check` validates structure, but only an actual
restore proves that repo, password, decrypt and restore path still turn into
real bytes.

Config is hand-managed on that host, in
`$HOME/.config/restic-maintenance/config` (start from `maintenance.config.sample`),
with each client's repo encryption password beside it as `encryption_pw_<name>`.
`deploy.sh` pushes to clients only and never touches any of it.

Four things to be deliberate about:

- **This host can decrypt everything.** It holds every client's encryption
  password, which makes it as sensitive as all the clients combined; `0600`,
  root-only, ideally on encrypted storage. The script refuses to start if its
  config or the directory holding it is group- or world-writable — that file is
  `source`d, so anything able to write it owns this host and every repo it
  reaches.
- **Prune takes the repo lock.** Clients wait `LOCK_WAIT` (default 15m) via
  `--retry-lock`, so schedule maintenance well away from the client window —
  with the default `BACKUP_WINDOW="23-06"`, and catch-up runs possible at any
  hour, late morning is the safe slot.
- **`restic check` doesn't read the data** by default. Set
  `CHECK_READ_DATA_SUBSET` (e.g. `"5%"`) and the script rotates a deterministic
  slice by day-of-year, covering the whole repo every 20 runs. restic's own `x%`
  form re-samples at random each run and never guarantees coverage, which is why
  the script converts the percentage into the `n/t` form itself.
- **`--group-by host` is load-bearing**, and lives in the script rather than in
  `FORGET_POLICY_DEFAULT` — a per-client override replaces the whole policy
  string, so leaving it in config lets a future override drop it silently on one
  client. restic's default is `host,paths`, which applies the keep-set
  separately to every distinct path set — and path sets move: adding `/boot` to
  a client's `BACKUP_PATHS` changes one, and so does a night where the dumps
  produce nothing, since the client appends `$DUMP_DIR` only when that directory
  has content. Each variant becomes its own group, and a group that stops
  receiving snapshots never ages out, because `--keep-daily N` keeps the last N
  days *that have snapshots*, not the last N days. The orphan is thinned once
  and pinned forever, where prune cannot reclaim it. One repo per client makes
  host grouping one group per repo, which is the intent everywhere here.

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
| ntfy (`urgent`) | First failure after a success; crossing `MAX_BACKUP_AGE_HOURS`; then every `NOTIFY_REPEAT_HOURS` | Success is intentionally silent. Throttled — see §4.3. |
| Local staleness check | Every invocation, including every skip | The fast alarm: catches a host that is alive but quietly not backing up. |
| ntfy (`low`) | Once per newly published script version, if this host is behind | Only when `NTFY_TOPIC_LOW` is set; otherwise a log line. Never updates anything — see §10. |
| healthchecks ping | `/start`, success, `/fail` | The slow alarm: catches a host too dead to alert for itself. Grace period should sit **above** `MAX_BACKUP_AGE_HOURS`. |
| `notify-send` | Failure, desktop only | Best-effort. |

Test the alerting path deliberately — point `RESTIC_REPOSITORY` at a bogus URL
and confirm the ntfy message and `/fail` ping actually arrive. Silent-on-success
monitoring is only as good as the last time you proved the alarm works.

The staleness path is worth testing too, and it is cheap:

```bash
# pretend the last success was 40h ago
printf '%s\n' $(( $(date +%s) - 40*3600 )) > /root/.config/restic/.last-success

restic-backup.sh --status   # 'stale: YES -- would alert'; exit 3, sends nothing
restic-backup.sh            # the real run: one urgent ntfy, one /fail ping
```

`--status` is the dry half of that test on purpose: it reports the verdict
without pinging anything and without touching `.notify-state`, so it cannot
spend the one alert the next real run was going to send.

Then let a real run repair it, or delete `.last-success` to reset.

---

## 9. Troubleshooting

| Symptom | Cause |
|---|---|
| `401 Unauthorized` | `RESTIC_REST_USERNAME` ≠ first path segment of the repo URL (`--private-repos`), or wrong htpasswd password. |
| Timeout / `unreachable` | WireGuard down. `wg show`, then `curl -i http://10.0.0.2:8000/`. |
| `repository is already locked` | Concurrent maintenance prune. Clients retry for `LOCK_WAIT`; raise it or move the maintenance window. |
| `Another run has held the lock for …; exiting.` | A previous run is still going (`flock`). Not an error while that time is under `MAX_BACKUP_AGE_HOURS`; past it the holder is treated as wedged and alerts. |
| `Not due …; exiting.` | Normal, 23 times a day. `--status` shows why. |
| Backup skipped, no alert | Metered link, tunnel down, or not due — and the last success is still within `MAX_BACKUP_AGE_HOURS`. By design; no ping is sent. |
| `STALE: no successful backup for …` | The hard fail. The host is alive but hasn't backed up in `MAX_BACKUP_AGE_HOURS`; the log line above it says which skip path it took. |
| `notification suppressed (already alerted…)` | Throttling (§4.3), not a new problem. The original push already went out. |
| Nothing runs at all after migrating | `/etc/cron.d` entry has a dot in its filename — cronie ignores it silently. Rename, `systemctl reload crond`. |
| `WG: 'wg-quick up wg0' FAILED — the tunnel is now DOWN` | The bounce brought the tunnel down and could not bring it back (endpoint unresolvable). Fix the tunnel by hand; the script won't try again for `WG_BOUNCE_INTERVAL_HOURS`. |
| `WG: already bounced … ago; waiting` | The bounce rate limit (§2.1), not a failure. The tunnel was restarted recently and the backend is still unreachable — the underlying problem is not one a bounce fixes. |
| `WG: no default route — host is offline` | Nothing to self-heal: the host has no route at all, so the tunnel is not the problem. Applies to `WG_RESTART_CMD` too. |
| Cron mails you 24 times a day | `MAILTO=""` missing from `/etc/cron.d/restic-backup`, or the `logger` redirect dropped. |
| Dump fails, whole backup aborts | Intended. Fix the dump — don't disable the check. |
| `no mariadb-dump/pg_dumpall in container` | `DOCKER_AUTO` on a SQLite container. Use `SQLITE_FILES` with the host path, or the hook. |
| Alert fires but no desktop popup | `notify-send` from a root cron job can't reach your session. The ntfy message is the real channel. |
| `this host is NOT running the published version` | Version drift. Nothing is broken and nothing was changed; push with `./deploy.sh`. |
| `version check could not reach …` | GitHub was unreachable. Advisory only — it runs after the backup and cannot affect it. |
| Exclude pattern silently ignored | restic treats `#` as a comment **only** at the start of a line. An inline comment becomes part of the pattern. |

---

## 10. Updating the fleet

Clients **never fetch code**. `restic-backup.sh` runs as root on every host, so
a fetch-and-exec updater would turn one GitHub credential — or one bad commit to
`main` — into root on the whole fleet, arriving within the hour now that cron
runs hourly. Updates are pushed by a human instead; the only thing the client
does on its own is *notice* that it is out of date.

### 10.1 Pushing

```bash
install -d -m 700 ~/.config/restic    # host list, paths, per-host cron minute
cp deploy.conf.sample ~/.config/restic/deploy.conf
$EDITOR ~/.config/restic/deploy.conf

./deploy.sh                 # plan → diff → confirm → push → show each --status
./deploy.sh --dry-run       # plan and diff only
./deploy.sh --check         # alert nobody; print every host's --status
                            # exits non-zero on a stale, unreachable or
                            # unscheduled host, so it works as a CI gate
./deploy.sh --host srv01    # one host (repeatable)
```

It deploys `restic-backup.sh`, `excludes`, and the cron entry — rendering the
latter with **that host's own minute** from `CRON_MINUTE`, which is the easiest
way to keep the fleet staggered. It never touches `config`, `encryption-pw`,
`pre-backup`, or `excludes.local`: those are per-host and hand-managed, and two
of them are secrets.

`excludes` is the fleet-wide base and is **overwritten in place**, so anything
you hand-edit onto a target is reverted by the next deploy — with no error, the
only symptom being a snapshot that quietly stopped containing something. Put
per-host patterns in `excludes.local` instead. restic reads it after `excludes`,
and a later pattern beats an earlier one, so that file can add exclusions *and*
take one back: `!.venv` there re-includes what the shared file drops. A host
with no `excludes.local` is the normal case — the flag is passed only when the
file exists.

Two details worth knowing:

- **It needs root on the target, and gets it through `sudo`.** It writes
  `/usr/local/sbin` and `/etc/cron.d`, and it reads, hashes and diffs
  `CONFIG_DIR` under `/root` — so the elevation is on every remote command, not
  just the writes. Set `SSH_USER` to the account you actually log in as; every
  command is then prefixed with `SUDO` (default `sudo -n`), which must be
  **passwordless**, since `SSH_OPTS` uses `BatchMode` and there is no terminal
  to answer a prompt on:

  ```bash
  # on each target, once
  echo 'youruser ALL=(root) NOPASSWD: ALL' | sudo tee /etc/sudoers.d/deploy-restic
  sudo chmod 440 /etc/sudoers.d/deploy-restic
  ```

  Where root logs in over ssh directly, leave `SSH_USER="root"` and the prefix
  drops out on its own. A refused `sudo` is reported as a sudo failure with the
  message the host gave, not as an unreachable host.
- **It installs by rename, not by copy.** `restic-backup.sh` may be running when
  you deploy, and bash reads its own source incrementally as it executes —
  overwriting it in place makes a live run execute whatever happens to land at
  the offset it reads next. `deploy.sh` writes `<dest>.new` and `mv`s it over,
  so a running backup keeps its original inode and finishes normally.
- **A syntax error never leaves the repo.** `bash -n` runs on the local file
  before anything is pushed.

`deploy.conf` lives in `~/.config/restic/`, not in the checkout. It is not
secret, but it describes one production fleet, and a working tree is not where
that belongs: a clone, a second worktree or a `git clean -xdf` each change what
the tree holds, and none of them should be able to change, carry or drop the
list of machines that get root-executed code pushed to them. `deploy.sh` reads
that path alone — `DEPLOY_CONF=path ./deploy.sh` overrides it — and **refuses to
run while a `deploy.conf` is left in the checkout**, rather than ignoring it:
two files of the same name, one of them live, is how an edit ends up in the one
nothing loads, and a deploy of the fleet the *other* file describes reports a
clean success.

Run `deploy.sh` as yourself. It needs no local root — the elevation it needs is
on the target, through `SUDO` — and under `sudo` `$HOME` is root's, so the host
list is looked for in `/root/.config/restic`.

#### Deploying to the machine you run it from

An admin box is usually a client too. Name it in `LOCAL_HOST` and its steps run
in a local shell instead of over ssh — same commands, same plan, same diff, same
prompt — so it needs no sshd and no key just to deploy to itself:

```bash
HOSTS=( srv01 srv02 laptop.lan )
LOCAL_HOST="laptop.lan"             # must be one of HOSTS
declare -A CRON_MINUTE=( [srv01]=07 [srv02]=23 [laptop.lan]=53 )
```

**One host, so it is a scalar.** `SBIN_PATH`, `CONFIG_DIR` and `CRON_PATH` are
one value each, and a second local host would write those same three files over
the first — cron minute included — on the same machine, reporting success both
times. Rather than a list plus a check that the list holds one thing, the name
is one that cannot hold two. Every other host setting here *is* a list, so
`LOCAL_HOST=( laptop.lan )` is an easy reflex and bash accepts it silently,
keeping only the first element; that spelling is refused with a message.

It is opt-in by name, not worked out from the hostname. Nothing distinguishes
*this* machine from a same-named one, and a guess that goes the wrong way skips
the network for a host you meant to reach across it — then reports a clean
deploy, having written the files on the admin box instead. A `LOCAL_HOST` that
is in neither list is refused rather than ignored.

Elevation is still `sudo`, but through `LOCAL_SUDO` (default `sudo`) rather than
`SUDO`. The `-n` in `SUDO` is there because `BatchMode` ssh has no terminal to
answer a password prompt on; a local run has yours, so deploying to the machine
you are sitting at needs no `NOPASSWD` rule. Where `deploy.sh` has no terminal
either — cron, CI, the runs `--yes` exists for — it puts the `-n` back on its
own, so a prompt fails fast instead of hanging a deploy nobody is watching.

Nothing else changes. `config`, `encryption-pw` and `pre-backup` are left alone
here exactly as they are on a remote host, and `restic-backup.sh` is still
written by rename rather than copied over — the run it must not disturb is the
hourly root cron job, which is on this machine too.

### 10.2 Noticing drift

Set `VERSION_CHECK_URL` in each client's config and the script compares itself
against the published copy — after a successful backup, at most once every
`VERSION_CHECK_INTERVAL_HOURS`, with every error swallowed. It can neither delay
nor block a backup, and it has no code path that writes to itself.

```console
# restic-backup.sh --check-update
version : DIFFERS from published -- local 975f2f8641ee, remote c99352ec3c19
```

Drift is logged on every run, shown in `--status`, and — if you set
`NTFY_TOPIC_LOW` — pushed once per newly published version, so publishing a
change nudges you once per stale host rather than once per run.

`./deploy.sh --check` gives you the same answer for the whole fleet at once,
which is usually what you actually want.

---

## Security model

| Control | Protects against |
|---|---|
| WireGuard | Anything on the public internet; provides encryption + peer auth for the hop. |
| `--append-only` | A compromised but validly-authenticated client deleting its own history (ransomware). |
| `--private-repos` + per-client htpasswd | Clients on the same WG subnet reading or deleting each other's backups. |
| Per-client encryption password | The backup host's storage being read or stolen. |
| `:ro` auth mount, `no-new-privileges` | A compromised rest-server container rewriting credentials or escalating. |
| `$DUMP_DIR` wiped on exit and on SIGTERM/INT/HUP, mode `0700` | Plaintext database dumps lingering on client disks. |
| Secrets via env / container env / `curl -K`, never argv | Passwords appearing in the host process list. |
| `config` and `pre-backup` refused unless root-owned and not group/world-writable | A writable config turning the hourly root cron job into unattended root code execution. |
| No self-update path; clients never fetch code | One compromised GitHub credential becoming root on every host within the hour. |

Not covered: the maintenance host is a single point of trust — it holds every
encryption password and has delete rights on every repo. If that matters for
your threat model, split retention per client or keep an off-site copy the
maintenance host cannot reach.

If you ever keep a filled-in `config` inside a git repo, add a `.gitignore` with
`config` and `encryption-pw` first — or better, keep them out of git entirely.

---

## Licence

MIT — see [LICENSE](LICENSE). The scripts run as root and handle your backups;
there is no warranty, so read them before you deploy them.
