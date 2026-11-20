# mamori-server-scripts

Scripts for operating and installing a Mamori server.

## Layout

| Path | Purpose |
|------|---------|
| `media/` | All-in-one install / upgrade / cleanup / uninstall / **backup & restore** |
| `firewall/` | Host firewall setup (ufw / firewalld) and validation |
| `ha/` | High-availability Postgres, app nodes, and load balancer |
| `lib/` | Shared helpers (portal root password, timezone/swap, firewall) |
| `server/` | Host checks (ports, dumps) |
| `nginx/` | Host nginx install/verify/upgrade, container & gateway SSL, config refresh |
| `cve-patches/` | Emergency CVE mitigations for running Mamori containers (patch + restart + verify) |
| `integrations/presidio/` | Presidio analyzer/anonymizer install, upgrade, uninstall (image build is `docker-db-scripts/presidio`) |
| `integrations/openbao/` | OpenBao install, Mamori AppRole/KV bootstrap, uninstall |
| `integrations/grafana-influx/` | Check that Hub, the web app, and Telegraf are writing into InfluxDB |

## Portal root password (`MAMORI_ROOT_PASSWORD`)

Docker images do **not** ship with a default portal `root` password. On first boot,
if `derby.user.root` is unset, the container requires `MAMORI_ROOT_PASSWORD`,
stores it encrypted, then clears it from the process environment.

Install helpers:

- `media/validate-install.sh` — ports, disk, Docker/Podman, hostname, timezone (list/set), swap (optional add); reports whether install will prompt for portal root (Ubuntu and Red Hat)
- `media/install-*.sh` — prompt for (or use exported) `MAMORI_ROOT_PASSWORD` on first create/start, then scrub it from the container
- `media/install-*.sh` and `media/upgrade-*.sh` — `--shm-size` defaults from host RAM; override with `--shm-size` (for example `--shm-size 1g`)
- `media/upgrade-aio-postgres-to-18.sh` — migrate AIO Postgres volumes 14→18 before a Mamori PG18 bundle upgrade
- `media/upgrade-*.sh --validate` — require on-disk AIO Postgres major to match the bundle (18)
- `ha/validate-new-node.sh` — without `--env-file` = first node (install will prompt); with `--env-file` = additional node
- `ha/install-ha-node.sh` / `ha/start-ha-node.sh` — no `--env-file` prompts for PG_* + portal root; `--env-file` never prompts; joining nodes get `DERBY_USER_ROOT` via extract/join; scrub after first boot

AIO validate examples:

```bash
bash validate-install.sh --list-timezones Australia
bash validate-install.sh --set-timezone Australia/Melbourne --add-swap
bash validate-install.sh
```

Do not leave `MAMORI_ROOT_PASSWORD` on a long-lived `docker create -e` definition.
Never store it in a host env file under this repo.

## Monitoring stack (Grafana / InfluxDB)

Pinned for packaging: **Grafana Enterprise 13.2.3**, **InfluxDB OSS 1.13.1**.

AIO containers mount Grafana and InfluxDB on named volumes, so upgrading the
image alone does not replace those binaries. The container name defaults to
`mamori` (`MAMORI_CONTAINER` overrides it).

Connected host (the container must reach the Mamori mirror or the upstream download):

```bash
cd media
sudo ./update-monitoring-in-container.sh
# sudo ./update-monitoring-in-container.sh grafana
# sudo ./update-monitoring-in-container.sh influxdb
```

Air-gapped host — build the media tarball on a connected machine, copy the `.tgz` over, then install from it. Nothing is downloaded at upgrade time.

```bash
# connected machine
cd media
./monitoring-get-media.sh --dir /tmp

# air-gapped Mamori host
cd media
sudo ./update-monitoring-in-container.sh --media=/tmp/mamori-monitoring-grafana-13.2.3-influxdb-1.13.1-linux-amd64.tgz
```

`--media` and `--media-file` are the same flag. The tarball must be `MEDIA_TYPE=mamori-monitoring` for Grafana 13.2.3 and InfluxDB 1.13.1.

A clean install can crash-loop Grafana 13 (`missing configuration for current encryption provider misconfigured`) and leak plugin processes until the container cannot fork. Packaged `defaults.ini` must stay; Mamori overlays go in `conf/custom.ini`. Nginx must 301 `/monitor` to `/monitor/` or the Monitor menu hits Phoenix (`Invalid URL`).

```bash
cd media
sudo ./fix_grafana_13.sh
sudo ./fix_grafana_13.sh --validate
```

`--validate` checks packaged defaults (`[secrets_manager]`, `[cloud_migration]`), `.defaults.keep`, `custom.ini` (encryption, alerting annotations, GMS off, `serve_from_sub_path`, JWT `url_login`), nginx `location = /monitor`, listen on 3000, `HTTP Server Listen` / `subUrl=/monitor`, no encryption/GMS/`newosproc` errors, and that plugin processes are not leaking. The default repair run applies those settings, then validates.

HA shared-services Grafana uses `ha/upgrade-shared-monitoring.sh` (same `custom.ini` overlays; do not bind Grafana to `127.0.0.1` on that host). On an air-gapped shared-services host, pass the same tarball: `sudo ./upgrade-shared-monitoring.sh --media=/path/to/mamori-monitoring-....tgz` after `--verify`. `--verify` does not take `--media`.

To check that Hub, the web app collector, and Telegraf are writing into InfluxDB:

```bash
cd integrations/grafana-influx
sudo ./healthcheck.sh
```

Image rebuilds (CI / docker tree) download media via
`/vagrant/docker/prepare_monitoring_media.sh`.

## AIO PostgreSQL 18 (new installs and upgrades)

New all-in-one Mamori images bundle **PostgreSQL 18** (port **54321**). A normal
Mamori image upgrade recreates the container but **keeps** the Postgres volumes,
so existing AIO sites on PostgreSQL 14 must migrate the data directory **before**
upgrading Mamori to a PG18-only bundle.

```bash
cd media
# 1) Migrate volumes 14 -> 18 (builds a dual-binary helper image on first run)
bash upgrade-aio-postgres-to-18.sh
# optional: bash upgrade-aio-postgres-to-18.sh --dry-run

# 2) Confirm on-disk PG major matches the bundle, then upgrade Mamori
bash upgrade-dockerhub.sh --validate   # or: bash upgrade-file.sh --validate
bash upgrade-dockerhub.sh              # or: bash upgrade-file.sh

# 3) After soak, remove leftover PG 14 data/config
bash upgrade-aio-postgres-to-18.sh --prune-old
```

Notes:

- `upgrade-dockerhub.sh` / `upgrade-file.sh` **always** gate on Postgres major
  (bundle expects **18**). `--validate` runs that check without upgrading.
- After a successful PG migrate, leave the old PG14-only Mamori container
  **stopped**. Do not start it against the migrated volumes; run the Mamori
  upgrade next in the same maintenance window.
- Helper pieces: `lib/aio-pg-version.sh`, `media/aio-pg-upgrade-helper/`,
  `media/config/pg18_conf.tgz`.

HA Postgres is separate (`ha/install-ha-postgres.sh`, official `postgres:18`).

## Upgrade cleanup and uninstall

After a verified upgrade, remove leftover backup containers/images:

```bash
cd media
bash cleanup.sh
```

Full uninstall (containers, images, and volumes — prompts before deleting volumes):

```bash
cd media
bash uninstall.sh
# bash uninstall.sh --keep-volumes   # keep mamori-* volumes
# bash uninstall.sh --yes            # skip volume confirmation
```

## All-in-one backup and restore

Migrate an all-in-one Mamori host by backing up named Docker volumes and the
`mamori-alpine-boringtun` helper image, then restoring them on a new host
**before** running the Mamori install.

On the **source** (Mamori running):

```bash
cd media
bash backup-aio.sh
# bash backup-aio.sh --output /path/to/mamori-backups
```

Copy the output directory (default `./mamori-backups`) to the **target**. The
target needs Docker installed; do not install Mamori yet.

On the **target**:

```bash
cd /path/to/mamori-backups
bash restore.sh
# or, from the scripts repo:
# bash /path/to/mamori-server-scripts/media/restore-aio.sh --backup /path/to/mamori-backups
```

Then run the normal AIO install (`media/install-*.sh`) so the `mamori`
container is created against the restored volumes.

## Host firewall

After install, configure the host firewall (Ubuntu `ufw` or Red Hat `firewalld`):

```bash
cd firewall
bash setup-firewall.sh
bash validate-firewall.sh
```

`setup-firewall.sh` always opens TCP 22 and 443, and prompts for WireGuard (CIDR), internet exposure, DB proxies, RDP, and WEB proxy. Profile is saved in `.mamori-firewall.env`.

With WireGuard enabled, clients on the WG CIDR may reach all host ports (DB, RDP 4822, WEB 8089) without opening those ports publicly. Opening any of those to any source on an internet-exposed host requires `--db-public` / `--rdp-public` / `--web-public`.

```bash
# Recommended for remote clients: WireGuard only
bash setup-firewall.sh --wireguard --wg-cidr 172.0.0.0/16 --no-prompt

# Private LAN: open optional ports
bash setup-firewall.sh --db-proxies --rdp --web-proxy --no-prompt
```

## Nginx (host package vs container)

**Host nginx** (any box, or HA deployed gateway with `--role gateway`):

```bash
cd nginx
sudo ./install-host-nginx.sh --verify
sudo ./install-host-nginx.sh --install
# HA gateway site:
# sudo ./install-host-nginx.sh --role gateway --install --seed-name m1 --seed-ip 10.x.x.x
```

**TLS at the LB (gateway host nginx):**

```bash
cd nginx
sudo bash nginx-update-gateway-ssl.sh /path/to/fullchain.crt /path/to/privkey.key
```

**TLS at the app node / AIO** (nginx inside the Mamori container):

```bash
cd nginx
sudo bash nginx-update-container-ssl.sh /path/to/fullchain.crt /path/to/privkey.key
# sudo bash nginx-update-container-ssl.sh cert.crt key.key --reload
```

**Upgrade nginx inside the Mamori container** (latest nginx.org stable, not a Mamori upgrade). Packages are `nginx` + `nginx-module-perl` from nginx.org, not the Ubuntu/RHEL nginx package.

Connected site (container must reach nginx.org):

```bash
cd nginx
sudo ./nginx-upgrade-container.sh --verify
sudo ./nginx-upgrade-container.sh --upgrade
```

Air-gapped site — build media on a connected machine, copy the `.tgz` over, then install from it:

```bash
# connected machine (matches current Mamori image: Ubuntu noble amd64)
./nginx-get-media.sh --dir /tmp
# ./nginx-get-media.sh --from-container mamori --dir /tmp
# ./nginx-get-media.sh --codename noble,jammy --dir /tmp

# air-gapped Mamori host
sudo ./nginx-upgrade-container.sh --upgrade --media-file=/tmp/nginx-org-stable-VERSION-ubuntu-noble-amd64.tgz
```

The new binary stays in the container writable layer until the container is recreated from a Mamori image.

HA gateway Mosquitto / HAProxy / node register: see `ha/HA-README.md`.
