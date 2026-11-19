# OpenBao host scripts

Install OpenBao on a host and bootstrap AppRole + KV settings for a Mamori
Secret Vaults integration (`OPENBAO`).

OpenBao is Vault-API compatible. These scripts use `curl` + `jq` against the
HTTP API (no local `bao` CLI required for bootstrap).

## Install (on the OpenBao host)

Debian/Ubuntu — downloads the official GitHub `.deb` (lab hosts often cannot
resolve `pkg.openbao.org`):

```bash
cd integrations/openbao
sudo bash install.sh
# sudo OPENBAO_VERSION=2.7.2 bash install.sh --force
```

Then initialize once and **save the JSON** (keys + root token):

```bash
export BAO_ADDR=https://127.0.0.1:8200
export BAO_SKIP_VERIFY=1
bao operator init -key-shares=1 -key-threshold=1 -format=json | tee openbao-state.json
bao operator unseal "$(jq -r '.keys_base64[0]' openbao-state.json)"
chmod 600 openbao-state.json
```

Default listener: HTTPS on `:8200` with a self-signed cert under `/opt/openbao/tls`.
UI: `https://<host>:8200/ui`

## Import into Mamori (Integrations UI)

Preferred path: **Mamori creates AppRole itself**. Use the init state file only for the create form.

From `bao operator init -format=json` / `openbao-state.json`:

| Integrations field | State field |
|--------------------|-------------|
| OpenBao address | `https://<host>:8200` |
| Unseal key(s) | `keys` or `keys_base64` (one per line) |
| Seal token | `root_token` (prefer rotating to a seal-only token later) |

Then in Mamori: **Server Settings → Integrations → Secret Vaults → OpenBao**

1. Add integration (address + key + token). Mamori stores key/token as **SYS.SECRETS**; reveal uses normal secret permission.
2. **Validate** / **Unseal** / **Seal** as needed.
3. **Create AppRole** — Mamori enables KV + AppRole on OpenBao and stores `role_id`/`secret_id` as another Mamori secret for resource get/set/list.

Do **not** commit `openbao-state.json`.

## Optional: host-side AppRole bootstrap

Ops can still pre-create AppRole on the OpenBao host (not required when using Mamori **Create AppRole**):

```bash
cd integrations/openbao
bash bootstrap-mamori.sh \
  --addr https://103.100.37.66:8200 \
  --state /path/to/openbao-state.json \
  --out /path/to/mamori-openbao-connection.json
```

That script unseals, enables KV-v2 + AppRole, writes policy/role, smoke-tests, and writes a connection JSON (chmod 600).

## Uninstall

```bash
cd integrations/openbao
sudo bash uninstall.sh
# sudo bash uninstall.sh --purge --yes   # also wipe /opt/openbao
```

## Environment

| Variable | Default | Meaning |
|----------|---------|---------|
| `BAO_SKIP_VERIFY` | `1` | Skip TLS verify (self-signed) |
| `BAO_KV_MOUNT` | `secret` | KV mount path |
| `BAO_POLICY_NAME` / `BAO_ROLE_NAME` | `mamori` | Policy and AppRole name |
| `BAO_SECRET_PREFIX` | `mamori` | KV path prefix for Mamori secrets |
| `OPENBAO_VERSION` | `2.7.2` | `.deb` version for `install.sh` |
