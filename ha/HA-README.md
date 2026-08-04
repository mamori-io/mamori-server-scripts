# HA app node — steps

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

### 7. Add the node to the load balancer (gateway host)

```bash
bash dump-lb-config.sh
bash manage-lb-node.sh --register --name <hostname> --ip <internal-ip>
bash dump-lb-config.sh
```

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

## Temporary HTTP UI test (no load balancer)

### Option A — curl (no nginx change)

curl stores Secure cookies even over HTTP; browsers do not.

```bash
rm -f /tmp/cj
curl -c /tmp/cj -b /tmp/cj -sS -o /dev/null http://127.0.0.1/
curl -c /tmp/cj -b /tmp/cj -sS -X POST http://127.0.0.1/sessions/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"omadmin","password":"YOUR_PASSWORD"}'
```

### Option B — browser (changes nginx temporarily)

```bash
bash enable-http-ui-test.sh
```

Test at `http://<node-ip>/#/login`.

```bash
bash restore-http-ui-test.sh
```

Clear browser cookies for the site (or use a private window) after restore.
