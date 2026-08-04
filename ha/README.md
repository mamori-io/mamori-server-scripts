# mamori HA scripts

Scripts for Mamori high-availability setup and maintenance.

## extract-cluster-details.sh

Run on an existing app-node **host** (no need to enter the container). It sets
`MAMORI_VAR` / `DERBY_PROPS` from the `mamori-var` Docker volume automatically.

```bash
bash /tmp/extract-cluster-details.sh -o /tmp/cluster-details.env
cat /tmp/cluster-details.env
```

Options: `-o/--output <file>`, `-a/--all` (dump every `rms.server_property`).

## validate-new-node.sh

Pre-flight checks on a **new** app node before install/join (ports, disk, Docker,
hostname, timezone `/etc/timezone`, swap). Uses [`server/server-port-check.sh`](../server/server-port-check.sh).

From the repo:

```bash
bash ha/validate-new-node.sh
```

On a remote node (copy both scripts into `/tmp`):

```bash
scp server/server-port-check.sh ha/validate-new-node.sh root@${HA_M3_HOST}:/tmp/
bash /tmp/validate-new-node.sh -o /tmp/validate-new-node.report
```

Exit `0` only if all hard checks pass.

## get-ha-media.sh

Download HA cluster node media (`mamori_cluster_docker.tgz`) per
[Install HA Services](https://doc.mamori.io/050-installation/ha-install).

```bash
bash ha/get-ha-media.sh --dir /tmp
# or on the new node:
bash /tmp/get-ha-media.sh --dir /tmp
```

Defaults to the **ga** channel. Use `--channel dev` for development media.
`--force` overwrites an existing tarball.

## install-ha-node.sh

Load the HA cluster image and `docker create` the app-node container (does **not**
start or join). Per [Install HA Services](https://doc.mamori.io/050-installation/ha-install).

```bash
bash /tmp/get-ha-media.sh --dir /tmp
bash /tmp/install-ha-node.sh --media /tmp/mamori_cluster_docker.tgz
```

Uses `/etc/timezone` for `TZ` when present. `--force` replaces an existing
container with the same name.

## join-ha-node.sh

Join the created container to the shared cluster DB using an env file from
`extract-cluster-details.sh`. Run **after** install, **before** `docker start`.

```bash
# on existing hub (m1):
bash /tmp/extract-cluster-details.sh -o /tmp/cluster-details.env

# copy cluster-details.env to the new node, then:
bash /tmp/join-ha-node.sh --env-file /tmp/cluster-details.env
docker start mamori
```

Requires `PG_HOST`, `PG_PORT`, `PG_USER`, `PG_PASSWORD` (and ideally
`MAMORI_ENCRYPTION_KEY`) in the env file.

## Node labels

| Name | Role | Host |
|------|------|------|
| **m1** | Live app node | via gateway → `m1` (`10.240.0.11`) |
| **m2** | Live app node | via gateway → `m2` (`10.240.0.228`) |
| **m3** | New app node | `112.213.34.86` (`node1`) |
| **gateway** | LB (HAProxy/nginx), SSH jump | `112.213.36.8:2200` |

## Testing an HA node without the load balancer

HA node nginx listens on **HTTP :80** and sets `X-Force-HTTPS`, so Phoenix issues
`WPORTALSESSION` with the **Secure** flag. Browsers will not store that cookie on
`http://`, which causes `POST /sessions/login` to fail.

Cluster nginx includes `proxy_cookie_flags WPORTALSESSION nosecure ...` so direct
HTTP UI testing works on the node. Prefer the LB/HTTPS for normal use.

Quick API check on the node:

```bash
rm -f /tmp/cj
curl -c /tmp/cj -b /tmp/cj -sS -o /dev/null http://127.0.0.1/
curl -c /tmp/cj -b /tmp/cj -sS -X POST http://127.0.0.1/sessions/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"USER","password":"PASS"}'
```
