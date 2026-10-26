# Presidio host scripts

Instantiate, upgrade, and uninstall the Presidio analyzer / anonymizer on a
host. Image **build** is in `/home/omasri/docker-db-scripts/presidio`.

Languages on the published image: **`en`** and **`th`** only.

## Install

Downloads the published archive and starts analyzer **:5002** + anonymizer **:5001**:

```text
https://mamori-io.sgp1.digitaloceanspaces.com/docker-images/mamori-presidio-en-th-20261023.tgz
```

```bash
cd integrations/presidio
bash install.sh
# bash install.sh --force
# bash install.sh /path/to/mamori-presidio-en-th-20261023.tgz
```

Point a Mamori Presidio integration at:

- Analyzer: `http://<host>:5002`
- Anonymizer: `http://<host>:5001`

## Upgrade

Fetches the Spaces archive again, loads it, and recreates the containers:

```bash
bash upgrade.sh
# bash upgrade.sh /path/to/newer-mamori-presidio-en-th-YYYYMMDD.tgz
```

## Uninstall

```bash
bash uninstall.sh
# bash uninstall.sh --yes
# bash uninstall.sh --keep-images --keep-cache --yes
```
