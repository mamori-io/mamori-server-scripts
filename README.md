# mamori-server-scripts

Scripts for operating and installing a Mamori server.

## Layout

| Path | Purpose |
|------|---------|
| `media/` | All-in-one install / upgrade / uninstall |
| `firewall/` | Host firewall setup (ufw / firewalld) and validation |
| `ha/` | High-availability Postgres, app nodes, and load balancer |
| `lib/` | Shared helpers (portal root password, timezone/swap, firewall) |
| `server/` | Host checks (ports, dumps) |
| `nginx/` | Nginx helpers |

## Portal root password (`MAMORI_ROOT_PASSWORD`)

Docker images do **not** ship with a default portal `root` password. On first boot,
if `derby.user.root` is unset, the container requires `MAMORI_ROOT_PASSWORD`,
stores it encrypted, then clears it from the process environment.

Install helpers:

- `media/validate-install.sh` — ports, disk, Docker/Podman, hostname, timezone (list/set), swap (optional add), portal root bootstrap (Ubuntu and Red Hat)
- `media/install-*.sh` — pass the env for first create/start, then scrub it from the container
- `ha/validate-new-node.sh` / `ha/install-ha-node.sh` / `ha/start-ha-node.sh` — same for HA

AIO validate examples:

```bash
bash validate-install.sh --list-timezones Australia
bash validate-install.sh --set-timezone Australia/Melbourne --add-swap
bash validate-install.sh
```

Do not leave `MAMORI_ROOT_PASSWORD` on a long-lived `docker create -e` definition.

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
