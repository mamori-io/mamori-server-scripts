# mamori-server-scripts

Scripts for operating and installing a Mamori server.

## Layout

| Path | Purpose |
|------|---------|
| `media/` | All-in-one install / upgrade / uninstall |
| `ha/` | High-availability Postgres, app nodes, and load balancer |
| `lib/` | Shared helpers (portal root password, host timezone/swap, scrub) |
| `server/` | Host checks (ports, dumps) |
| `nginx/` | Nginx helpers |

## Portal root password (`MAMORI_ROOT_PASSWORD`)

Docker images do **not** ship with a default portal `root` password. On first boot,
if `derby.user.root` is unset, the container requires `MAMORI_ROOT_PASSWORD`,
stores it encrypted, then clears it from the process environment.

Install helpers:

- `media/validate-install.sh` — Docker, `/etc/timezone` (offer to set), swap (offer to add 4GB), and prompts when a fresh `mamori-var` needs bootstrap
- `media/install-*.sh` — pass the env for first create/start, then scrub it from the container
- `ha/validate-new-node.sh` / `ha/install-ha-node.sh` / `ha/start-ha-node.sh` — same for HA

Flags for AIO validate: `--set-timezone Region/City`, `--add-swap`, `--no-prompt`.

Do not leave `MAMORI_ROOT_PASSWORD` on a long-lived `docker create -e` definition.
