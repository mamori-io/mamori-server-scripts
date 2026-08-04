# HA scripts

Server scripts for Mamori HA app nodes. For run order and commands, see
[HA-README.md](HA-README.md).

Docs: [HA install](https://doc.mamori.io/050-installation/ha-install).

Each script accepts `-h` / `--help`.

## extract-cluster-details.sh

Run on an existing app-node **host**. Resolves `MAMORI_VAR` from the `mamori-var`
Docker volume, reads derby properties and Postgres `rms.server_property`, and
writes a `cluster-details.env` for joining a new node.

- `-o` / `--output <file>` — output path
- `-a` / `--all` — dump every `rms.server_property`

## validate-new-node.sh

Pre-flight checks on a **new** app node before install/join: ports, disk,
Docker (≥26), hostname, `/etc/timezone`. Swap is warn-only.

Uses [`server/server-port-check.sh`](../server/server-port-check.sh) (keep repo
layout, or copy that script alongside).

- `-o` / `--output <file>` — write a report file

Exit `0` only if all hard checks pass.

## get-ha-media.sh

Downloads HA cluster media (`mamori_cluster_docker.tgz`).

- `--dir <path>` — download directory
- `--channel ga|dev` — media channel (default: `ga`)
- `--force` — overwrite existing tarball

## install-ha-node.sh

`docker load`s the HA image and `docker create`s the app-node container.
Does **not** start or join. Uses HA volumes only (`mamori-var`,
`mamori-nginx-conf`). Sets `TZ` from `/etc/timezone` when present.

- `--media <tarball>` — path to `mamori_cluster_docker.tgz`
- `-n` / `--name <container>` — container name (default: `mamori`)
- `--force` — replace an existing container with the same name

## join-ha-node.sh

Joins a created (not yet started) container to the shared cluster DB using
an env file from `extract-cluster-details.sh`.

Requires `PG_HOST`, `PG_PORT`, `PG_USER`, `PG_PASSWORD` (and ideally
`MAMORI_ENCRYPTION_KEY`) in the env file.

- `--env-file <file>` — cluster details env file
- `-n` / `--name <container>` — container name (default: `mamori`)

Run **after** `install-ha-node.sh` and **before** `docker start`.

## enable-http-ui-test.sh

Temporarily allows browser UI login over plain HTTP. Backs up the secure
nginx config under `/opt/mamori/http-ui-test-backup/`, adds
`proxy_cookie_flags WPORTALSESSION nosecure`, and restarts nginx.

- `-n` / `--name <container>` — container name (default: `mamori`)

## restore-http-ui-test.sh

Restores the backed-up secure nginx config after
`enable-http-ui-test.sh` and restarts nginx.

- `-n` / `--name <container>` — container name (default: `mamori`)
- `-f` / `--file <path>` — specific backup file (default: active/latest backup)
