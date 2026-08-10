# HA cluster — steps

Scripts live in this `ha/` directory. Clone the repo:

```bash
git clone https://github.com/mamori-io/mamori-server-scripts.git
cd mamori-server-scripts/ha
```

Docs: [HA install](https://doc.mamori.io/050-installation/ha-install).

## Servers and services

| Server | Services |
|--------|----------|
| **LB / gateway** | nginx (HTTPS → app `:80`), HAProxy (DB/SSH/etc. proxies → app nodes) |
| **App nodes** | Mamori container only (`mamori-var`, `mamori-nginx-conf`) |
| **Postgres box** | PostgreSQL 18 (`mamorisys`, `audit`, `xcs`), remote SCRAM-SHA-256 auth |
| **Shared-services box** | Mosquitto (`:1883`), InfluxDB (`:8086`), Grafana (`:3000`) |

Do **not** put Mosquitto / Influx / Grafana on the LB or Postgres host. App nodes do not run local Postgres/Influx/Grafana volumes.

```
  Clients
     |
     v
 +--------+----------+       +------------------+
 | LB / gateway      | ----> | App node 1..N    |
 | nginx + HAProxy   |       | mamori container |
 +--------+----------+       +--------+---------+
                                      |
              +-----------------------+-----------------------+
              |                                               |
              v                                               v
     +----------------+                            +------------------------+
     | Postgres box   |                            | Shared-services box    |
     | PostgreSQL 18  |                            | Mosquitto              |
     | mamorisys      |                            | InfluxDB + Grafana     |
     | audit, xcs     |                            +------------------------+
     +----------------+
```

---

## Bootstrap shared Postgres (Postgres box)

```bash
bash install-ha-postgres.sh --password 'choose-a-strong-password'
```

Verify from another host:

```bash
PGPASSWORD='choose-a-strong-password' psql --host <pg-host> --port 5432 -U postgres -d mamorisys -c 'select version()'
```

---

## First app node (prime the DB)

On node1, prepare a join env file (example):

```bash
cat >/tmp/cluster-details.env <<'EOF'
PG_HOST=<pg-host>
PG_PORT=5432
PG_USER=postgres
PG_PASSWORD=choose-a-strong-password
# MAMORI_ENCRYPTION_KEY=...   # set when joining an existing cluster
EOF
```

```bash
bash validate-new-node.sh
bash get-ha-media.sh --dir /tmp
bash install-ha-node.sh --media /tmp/mamori_cluster_docker.tgz
bash join-ha-node.sh --env-file /tmp/cluster-details.env
docker start mamori
```

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

## Shared-services — Mosquitto (required for multi-node)

Install Eclipse Mosquitto on the **shared-services** host (Docker). Example:

```bash
mkdir -p /opt/mamori/mosquitto/{data,log}
cat >/opt/mamori/mosquitto/mosquitto.conf <<'EOF'
persistence true
persistence_location /mosquitto/data/
log_dest file /mosquitto/log/mosquitto.log
bind_address 0.0.0.0
allow_anonymous true
EOF

docker create --name mosquitto --restart always --network host \
  --log-opt max-size=10m --log-opt max-file=5 \
  -v /opt/mamori/mosquitto/mosquitto.conf:/mosquitto/config/mosquitto.conf \
  -v /opt/mamori/mosquitto/data:/mosquitto/data \
  -v /opt/mamori/mosquitto/log:/mosquitto/log \
  eclipse-mosquitto
docker start mosquitto
```

On node1:

```bash
docker exec -it mamori msql "call SET_SERVER_PROPERTY('mqtt_server', 'tcp://<shared-services-host>:1883')"
docker exec -it mamori msql "sv restart mamori_fqod"
```

---

## Load balancer (gateway host)

Configure nginx (HTTPS → app upstream) and HAProxy (proxies → app backends) with node1 registered. If using HAProxy PROXY protocol:

```bash
docker exec -it mamori msql "call SET_SERVER_PROPERTY('haproxy', 'true')"
docker exec -it mamori msql "sv restart mamori_fqod"
```

Use `dump-lb-config.sh` / `manage-lb-node.sh` once nginx and HAProxy configs exist on the gateway.

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
bash validate-new-node.sh
```

### 3. Download HA media (new node)

```bash
bash get-ha-media.sh --dir /tmp
```

### 4. Create the container (new node)

Do not start yet.

```bash
bash install-ha-node.sh --media /tmp/mamori_cluster_docker.tgz
```

### 5. Join the cluster (new node)

```bash
bash join-ha-node.sh --env-file /tmp/cluster-details.env
```

### 6. Start the node

```bash
docker start mamori
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

Install InfluxDB and Grafana on the **same shared-services** host (see historical media steps in older HA notes, or Mamori support). Then on an app node:

```bash
docker exec -it mamori msql "call SET_SERVER_PROPERTY('influxdb_write_url', 'http://<shared-services-host>:8086/write?db=mamori')"
```

Grafana UI is typically `http://<shared-services-host>:3000/monitor` (or proxied via the LB `/monitor`).

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

Use these checks on **every** new app node (including node1) after `docker start mamori` and **before** `manage-lb-node.sh --register`. Default HA nginx keeps Secure session cookies (correct behind HTTPS LB); browsers will not log in over plain HTTP until Option B temporarily adjusts nginx.

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
