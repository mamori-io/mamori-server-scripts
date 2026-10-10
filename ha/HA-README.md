# HA cluster — steps

Scripts live in this `ha/` directory. Clone the repo:

```bash
git clone https://github.com/mamori-io/mamori-server-scripts.git
cd mamori-server-scripts/ha
```

Docs: [HA install](https://doc.mamori.io/050-installation/ha-install).

## Servers and services

Two front-door topologies are supported. Shared pieces (Postgres, app nodes, Grafana/Influx) are the same; Mosquitto and LB software differ.

| | **Cloud LB (A)** | **Deployed gateway (B)** |
|--|------------------|--------------------------|
| HTTPS / UI | Customer cloud LB | Host nginx on gateway |
| DB / SSH proxies | Customer network → app ports | Host HAProxy on gateway |
| Mosquitto | Monitoring box | Gateway |
| Grafana + Influx | Monitoring box | Monitoring box |
| App nginx | Inside Mamori container | Inside Mamori container |

**HTTPS TLS** may terminate at the **LB** or at the **app node** (container nginx). That choice is independent of A vs B. See the public HA install doc for SSL ops scripts.

```
Scenario B (deployed gateway) — typical:

  Clients --> gateway (nginx + HAProxy + Mosquitto) --> app nodes
       app nodes --> Postgres
       app nodes --> monitoring (Grafana + Influx)

Scenario A (cloud LB):

  Clients --> cloud LB --> app nodes
       app nodes --> Postgres
       app nodes --> monitoring (Mosquitto + Grafana + Influx)
```

App nodes do not run local Postgres/Influx/Grafana volumes.

---

## Bootstrap shared Postgres (Postgres box)

### Docker Postgres (provided script)

Installs PostgreSQL 18, then initializes and checks `mamorisys` / `audit` / `xcs`:

```bash
bash install-ha-postgres.sh --password 'choose-a-strong-password'
```

### Your own Postgres (native or managed)

Configure remote SCRAM-SHA-256 auth and network access yourself, then:

```bash
bash init-ha-postgres.sh --host <pg-host> --port 5432 --user postgres --password 'choose-a-strong-password'
bash check-ha-postgres.sh --host <pg-host> --port 5432 --user postgres --password 'choose-a-strong-password'
```

Verify from an app-node host:

```bash
PGPASSWORD='choose-a-strong-password' psql --host <pg-host> --port 5432 -U postgres -d mamorisys -c 'select version()'
```

---

## First app node (prime the DB)

No hand-written env file. `install-ha-node.sh` without `--env-file` prompts for
Postgres (`PG_*`) and the portal root password, checks that `mamorisys` is
unprimed, and writes `/tmp/cluster-details.env` for join.

```bash
bash validate-new-node.sh
bash get-ha-media.sh --dir /tmp
bash install-ha-node.sh --media /tmp/mamori_cluster_docker.tgz
# prompts PG_* + portal root; writes /tmp/cluster-details.env
bash join-ha-node.sh --env-file /tmp/cluster-details.env
bash start-ha-node.sh
```

First boot stores the portal root encrypted and primes shared schema;
`start-ha-node.sh` then removes `MAMORI_ROOT_PASSWORD` from the container.
Additional nodes use `--env-file` from `extract-cluster-details.sh` (includes
`DERBY_USER_ROOT`) and never prompt.

First boot creates schema/objects in the shared databases. Watch progress:

```bash
docker exec -it mamori tail -F /opt/mamori/var/log/mamori_fqod.log
```

### Verify the node (before the load balancer)

Confirm the node is healthy **before** putting it behind nginx/HAProxy. Use the HTTP UI test methods below (same as [Verify a node before the load balancer](#verify-a-node-before-the-load-balancer)).

**Option A — curl** (no nginx change):

```bash
rm -f /tmp/cj
curl -c /tmp/cj -b /tmp/cj -sS -o /dev/null http://127.0.0.1/
curl -c /tmp/cj -b /tmp/cj -sS -X POST http://127.0.0.1/sessions/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"root","password":"YOUR_PASSWORD"}'
```

**Option B — browser** (temporary nginx change):

```bash
bash enable-http-ui-test.sh
# open http://<node-ip>/#/login and sign in
bash restore-http-ui-test.sh
```

Clear browser cookies (or use a private window) after restore.

---

## Mosquitto (required for multi-node)

Run on the **monitoring** host (scenario A) or the **gateway** host (scenario B):

```bash
sudo ./install-ha-mosquitto.sh --verify
sudo ./install-ha-mosquitto.sh --install
```

On node1 (use the host where Mosquitto runs):

```bash
docker exec -it mamori msql "call SET_SERVER_PROPERTY('mqtt_server', 'tcp://<mosquitto-host>:1883')"
docker exec -it mamori sv restart mamori_fqod
```

---

## Deployed gateway (scenario B) — nginx + HAProxy

After app node1 is verified off-LB, on the **gateway** host:

```bash
# 1) Mosquitto (if not already on gateway)
sudo ./install-ha-mosquitto.sh --verify
sudo ./install-ha-mosquitto.sh --install

# 2) HAProxy (seed first app node)
sudo ./install-ha-haproxy.sh --verify
sudo ./install-ha-haproxy.sh --install --seed-name m1 --seed-ip <node1-ip>

# 3) Host nginx (Mamori LB site)
cd ../nginx
sudo ./install-host-nginx.sh --role gateway --verify
sudo ./install-host-nginx.sh --role gateway --install --seed-name m1 --seed-ip <node1-ip>
sudo ./nginx-update-gateway-ssl.sh /path/to/fullchain.crt /path/to/privkey.key

# 4) Register node1
cd ../ha
bash manage-lb-node.sh --verify
bash manage-lb-node.sh --register --name m1 --ip <node1-ip>
bash dump-lb-config.sh
```

If using HAProxy PROXY protocol, on node1:

```bash
docker exec -it mamori msql "call SET_SERVER_PROPERTY('haproxy', 'true')"
docker exec -it mamori sv restart mamori_fqod
```

**Scenario A** (cloud LB): skip HAProxy / host nginx / `manage-lb-node.sh`. Point the cloud LB at app nodes; use `nginx-update-container-ssl.sh` only if TLS terminates on the app node.

---

## Add a new HA app node

### 1. Extract cluster details (existing hub host)

```bash
bash extract-cluster-details.sh -o /tmp/cluster-details.env
```

Copy `cluster-details.env` to the new node.

### 2. Validate the new node

Requires `server-port-check.sh` available as `../server/server-port-check.sh` (or copy it alongside).

```bash
bash validate-new-node.sh --env-file /tmp/cluster-details.env
```

### 3. Download HA media (new node)

```bash
bash get-ha-media.sh --dir /tmp
```

### 4. Create the container (new node)

Do not start yet. Pass `--env-file` so install never prompts (additional node).

```bash
bash install-ha-node.sh --env-file /tmp/cluster-details.env --media /tmp/mamori_cluster_docker.tgz
```

### 5. Join the cluster (new node)

Applies Postgres settings and `DERBY_USER_ROOT` from `cluster-details.env`.

```bash
bash join-ha-node.sh --env-file /tmp/cluster-details.env
```

### 6. Start the node

```bash
bash start-ha-node.sh
```

Wait until the node has finished starting (for example `docker exec -it mamori tail -F /opt/mamori/var/log/mamori_fqod.log`).

### 7. Verify the node (before the load balancer)

Do **not** register the node on the LB until login works on the node itself.

**Option A — curl** (no nginx change; curl keeps Secure cookies over HTTP):

```bash
rm -f /tmp/cj
curl -c /tmp/cj -b /tmp/cj -sS -o /dev/null http://127.0.0.1/
curl -c /tmp/cj -b /tmp/cj -sS -X POST http://127.0.0.1/sessions/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"root","password":"YOUR_PASSWORD"}'
```

**Option B — browser** (`enable-http-ui-test.sh` / `restore-http-ui-test.sh`):

```bash
bash enable-http-ui-test.sh
# open http://<node-ip>/#/login and sign in
bash restore-http-ui-test.sh
```

Clear browser cookies (or use a private window) after restore. See [Verify a node before the load balancer](#verify-a-node-before-the-load-balancer) for notes.

### 8. Add the node to the load balancer (gateway host)

```bash
bash dump-lb-config.sh
bash manage-lb-node.sh --register --name <hostname> --ip <internal-ip>
bash dump-lb-config.sh
```

---

## Shared-services — Influx + Grafana (optional monitoring)

Target versions: **InfluxDB OSS 1.13.1** (keep `/write?db=mamori`) and **Grafana Enterprise 13.2.3**.

Install InfluxDB and Grafana on the **same shared-services** host (see historical media steps in older HA notes, or Mamori support). Then on an app node:

```bash
docker exec -it mamori msql "call SET_SERVER_PROPERTY('influxdb_write_url', 'http://<shared-services-host>:8086/write?db=mamori')"
```

Grafana UI is typically `http://<shared-services-host>:3000/monitor` (or proxied via the LB `/monitor`).

To upgrade **HA / shared-services** Grafana/Influx on the monitoring host:

```bash
cd /path/to/mamori-server-scripts/ha

# 1) Discover layout and write monitoring-upgrade.env (required before upgrade)
sudo ./upgrade-shared-monitoring.sh --verify

# 2) Upgrade using that profile
sudo ./upgrade-shared-monitoring.sh                   # both
# sudo ./upgrade-shared-monitoring.sh grafana
# sudo ./upgrade-shared-monitoring.sh influxdb

# Optional: explicit profile path
# sudo ./upgrade-shared-monitoring.sh --verify --config /var/lib/mamori/monitoring-upgrade.env
# sudo ./upgrade-shared-monitoring.sh --config /var/lib/mamori/monitoring-upgrade.env
```

`--verify` **discovers** the install (does not hard-code paths), validates it, and writes a profile (`monitoring-upgrade.env` next to the script by default). Supported layouts include:

- Grafana `host-tree` (`/opt/grafana` bind-mounted into a container) or `container-fs` (binaries inside e.g. `mamori-grafana` / `grafana` at `/opt/mamori/grafana`)
- InfluxDB `host-tree` (`/opt/influxdb`), `host-package` (`/usr/bin/influxd` + `/etc/influxdb`), or `container`

The upgrade **refuses to run** without a profile from a successful `--verify`. Re-run `--verify` after upgrading to refresh recorded versions.

For an **AIO** container whose Grafana/Influx binaries live on Docker volumes, use `media/update-monitoring-in-container.sh` instead.

Grafana 13 no longer ships `grafana-server`; start with `grafana server` (upgrade scripts install a shim for older entrypoints).

Upgrades also replace `conf/defaults.ini` from the Grafana package and ensure `conf/custom.ini` has `[secrets_manager]` plus `[unified_alerting.state_history] backend = annotations`. Leaving a pre-13 `defaults.ini` in place causes Grafana to crash-loop (nginx `/monitor/` → 502).

---

## Manage load-balancer nodes (gateway host)

```bash
bash dump-lb-config.sh

bash manage-lb-node.sh --disable --name <hostname>
bash manage-lb-node.sh --enable --name <hostname>
bash manage-lb-node.sh --unregister --name <hostname>
```

Optional:

```bash
bash manage-lb-node.sh --register --name <hostname> --ip <internal-ip> --dry-run
```

---

## Verify a node before the load balancer

Use these checks on **every** new app node (including node1) after `start-ha-node.sh` and **before** `manage-lb-node.sh --register`. Default HA nginx keeps Secure session cookies (correct behind HTTPS LB); browsers will not log in over plain HTTP until Option B temporarily adjusts nginx.

### Option A — curl (no nginx change)

curl stores Secure cookies even over HTTP; browsers do not.

```bash
rm -f /tmp/cj
curl -c /tmp/cj -b /tmp/cj -sS -o /dev/null http://127.0.0.1/
curl -c /tmp/cj -b /tmp/cj -sS -X POST http://127.0.0.1/sessions/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"root","password":"YOUR_PASSWORD"}'
```

A successful login response means the node can authenticate against the shared cluster.

### Option B — browser (changes nginx temporarily)

```bash
bash enable-http-ui-test.sh
```

Test at `http://<node-ip>/#/login`.

```bash
bash restore-http-ui-test.sh
```

Clear browser cookies for the site (or use a private window) after restore. Always restore before registering the node on the load balancer.
