# HA scripts

Server scripts for Mamori HA: shared Postgres, app nodes, and the gateway load balancer.
For run order and host roles, see [HA-README.md](HA-README.md).

Docs: [HA install](https://doc.mamori.io/050-installation/ha-install).

Each script accepts `-h` / `--help`.

## Shared Postgres (Postgres box)

### install-ha-postgres.sh

Pulls the Docker Official Image `postgres:18`, starts a persistent container
with remote SCRAM-SHA-256 auth, then runs `init-ha-postgres.sh` and
`check-ha-postgres.sh`.

- `-p` / `--password <secret>` — required (or `POSTGRES_PASSWORD`)
- `-n` / `--name <container>` — container name (default: `postgres`)
- `-i` / `--image <image>` — image tag (default: `postgres:18`)
- `-v` / `--volume <name>` — data volume (default: `mamori-pg-data` → `/var/lib/postgresql`)
- `--port <port>` — host port (default: `5432`)
- `-f` / `--force` — replace an existing container with the same name
- `--force-volume` — with `--force`, also delete the data volume

### init-ha-postgres.sh

Create empty databases `mamorisys`, `audit`, and `xcs` on an **existing**
Postgres instance (native, managed, or the container from
`install-ha-postgres.sh`). Idempotent. Does not install Postgres or change
`pg_hba.conf`.

- `--host` / `--port` / `--user` / `-p` `--password` (or `PG_*`)
- `-n` / `--container` — `docker exec` instead of host `psql`

### check-ha-postgres.sh

Verify Postgres is reachable and `mamorisys`, `audit`, and `xcs` exist.
Exit `0` only if all hard checks pass. Same connection flags as init.
Warns if `password_encryption` is not `scram-sha-256`.

## App-node scripts

### extract-cluster-details.sh

Run on an existing app-node **host**. Resolves `MAMORI_VAR` from the `mamori-var`
Docker volume, reads derby properties and Postgres `rms.server_property`, and
writes a `cluster-details.env` for joining a new node (includes
`DERBY_USER_ROOT`).

- `-o` / `--output <file>` — output path
- `-a` / `--all` — dump every `rms.server_property`

### validate-new-node.sh

Pre-flight checks on a **new** app node before install/join: ports, disk,
Docker (≥26), hostname, `/etc/timezone`. Swap is warn-only.
Also reports install role: without `--env-file`, first node (install prompts for
Postgres and portal root); with `--env-file`, additional node (no prompts).

Uses [`server/server-port-check.sh`](../server/server-port-check.sh) (keep repo
layout, or copy that script alongside).

- `-o` / `--output <file>` — write a report file
- `-e` / `--env-file <path>` — additional-node cluster-details.env

Exit `0` only if all hard checks pass.

### get-ha-media.sh

Downloads HA cluster media (`mamori_cluster_docker.tgz`).

- `--dir <path>` — download directory
- `--channel ga|dev` — media channel (default: `ga`)
- `--force` — overwrite existing tarball

### install-ha-node.sh

`docker load`s the HA image and `docker create`s the app-node container.
Does **not** start or join. Uses HA volumes only (`mamori-var`,
`mamori-nginx-conf`). Sets `TZ` from `/etc/timezone` when present.

Role is determined by `--env-file`:
- **No `--env-file` (first node):** prompt for `PG_*` and portal root; verify
  `mamorisys` is unprimed; write `--write-env` (default `/tmp/cluster-details.env`)
  for join; pass `MAMORI_ROOT_PASSWORD` when needed.
- **`--env-file` (additional):** never prompt; verify DB is primed; join applies
  `DERBY_USER_ROOT`.

- `--media <tarball>` — path to `mamori_cluster_docker.tgz`
- `-e` / `--env-file <path>` — additional-node cluster-details.env
- `-o` / `--write-env <path>` — first-node output env path
- `-n` / `--name <container>` — container name (default: `mamori`)
- `--force` — replace an existing container with the same name

### join-ha-node.sh

Joins a created (not yet started) container to the shared cluster DB using
an env file from `extract-cluster-details.sh`. Also applies `DERBY_USER_ROOT`
when present so additional nodes do not need `MAMORI_ROOT_PASSWORD`.

Requires `PG_HOST`, `PG_PORT`, `PG_USER`, `PG_PASSWORD` (and ideally
`MAMORI_ENCRYPTION_KEY` and `DERBY_USER_ROOT`) in the env file.

- `--env-file <file>` — cluster details env file
- `-n` / `--name <container>` — container name (default: `mamori`)

Run **after** `install-ha-node.sh` and **before** `start-ha-node.sh`.

### start-ha-node.sh

Starts the app-node container, then recreates it **without**
`MAMORI_ROOT_PASSWORD` once `derby.user.root` is stored (so the secret is
not left on the container config). Also removes a legacy
`.mamori-root-password.env` if present from older script versions.

- `-n` / `--name <container>` — container name (default: `mamori`)

### enable-http-ui-test.sh

Temporarily allows browser UI login over plain HTTP. Use after
`docker start` to **verify a node before registering it on the LB**.
Backs up the secure nginx config under `/opt/mamori/http-ui-test-backup/`,
adds `proxy_cookie_flags WPORTALSESSION nosecure`, and restarts nginx.
Always run `restore-http-ui-test.sh` when finished (and before LB register).

- `-n` / `--name <container>` — container name (default: `mamori`)

### restore-http-ui-test.sh

Restores the backed-up secure nginx config after
`enable-http-ui-test.sh` and restarts nginx.

- `-n` / `--name <container>` — container name (default: `mamori`)
- `-f` / `--file <path>` — specific backup file (default: active/latest backup)

## Gateway / load-balancer scripts

### dump-lb-config.sh

Prints nginx `upstream hub`, HAProxy listen backends, matching `/etc/hosts`
entries, and a per-node up/down summary.

- `--full` — also print the full HAProxy config
- `--hosts` / `--nginx` / `--haproxy` — override config paths

### manage-lb-node.sh

Register, unregister, enable, or disable an HA app node in `/etc/hosts`,
nginx `upstream hub`, and every HAProxy listen that already has hub servers.
Backups go under `/opt/mamori/lb-backup/`.

Actions (exactly one):

- `--register` — requires `--name` and `--ip`
- `--unregister` — requires `--name`
- `--enable` / `--disable` — requires `--name` (nginx `down`, HAProxy `disabled`)

Options:

- `--name <hostname>` — backend name used in configs (e.g. `m3`)
- `--ip <address>` — required for `--register`
- `--server-id <id>` — HAProxy id (default `mamorihubN` when name is `mN`)
- `--dry-run` — print planned changes only
- `--no-reload` — write files; skip `nginx -t` and service reloads
- `--hosts` / `--nginx` / `--haproxy` / `--backup-dir` — override paths
