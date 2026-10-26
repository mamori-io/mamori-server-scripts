# Presidio (English + Thai)

Offline deploy of the stack running on the Mamori Presidio host
(`mamori-presodio`, analyzer `http://66.226.150.208:5002`).

## Languages

**No — this image is not multilingual.** It only serves **`en`** and **`th`**.

Mamori Hub probes 30 language codes on Test Connection. On this host only
`en` and `th` return entities; every other code (`es`, `de`, `fr`, `it`,
`pt`, `ja`, `zh`, `ar`, `ru`, `ko`, …) returns
`No matching recognizers were found`.

| Language | NLP | What it detects |
| --- | --- | --- |
| **en** | spaCy `en_core_web_lg` | PERSON, LOCATION, DATE_TIME, EMAIL, PHONE, CREDIT_CARD, URL, IP, IBAN, CRYPTO, plus US/UK IDs (SSN, passport, driver license, NHS, …) |
| **th** | blank spaCy `th` + PyThaiNLP | PERSON (Thai names), TH_TNIN, plus language-agnostic EMAIL / PHONE / CREDIT_CARD / URL / IP / IBAN / CRYPTO / DATE_TIME / LOCATION / NRP / MEDICAL_LICENSE |

Stock Presidio is English-only. This image adds Thai NER (`ThaiPersonRecognizer`
via PyThaiNLP) and Thai national ID (`ThTninRecognizer`). Country recognizers
for Spain, Italy, Germany, Korea, etc. exist in YAML but stay unloaded because
those languages are not in `supported_languages`.

To add Spanish, German, Japanese, Chinese, … you must install extra spaCy (or
Stanza) models, list them in `analyzer/default.yaml`, and add the language
codes to `analyzer/default_analyzer.yaml`. That is a new image, not this tgz.

## Offline images

Built from the running containers on 2026-10-26:

- `mamori/presidio-analyzer:thai` (custom, English + Thai)
- `ghcr.io/data-privacy-stack/presidio-anonymizer:latest` (stock)

Archive on the Presidio host:

```text
/root/presidio-scan/out/mamori-presidio-en-th-20261023.tgz   (617M)
md5 37d53a236101f8867586a05cbadae37e
```

Copy it down:

```bash
scp -i ~/.ssh/id_rsa root@66.226.150.208:/root/presidio-scan/out/mamori-presidio-en-th-20261023.tgz .
```

The `.tgz` is a `docker save | gzip` of both images (not the container
filesystem). It is gitignored; do not commit it.

## Deploy

```bash
cd integrations/presidio
bash load-and-run.sh /path/to/mamori-presidio-en-th-20261023.tgz
```

Or:

```bash
gunzip -c mamori-presidio-en-th-20261023.tgz | docker load
docker compose up -d
curl http://127.0.0.1:5002/health    # Presidio Analyzer service is up
curl http://127.0.0.1:5001/health    # Presidio Anonymizer service is up
```

Ports match the current host: **5002** analyzer, **5001** anonymizer.

Point a Mamori Presidio integration at:

- Analyzer: `http://<host>:5002`
- Anonymizer: `http://<host>:5001`

## Rebuild (optional)

Needs network access to GHCR:

```bash
cd analyzer
docker build -t mamori/presidio-analyzer:thai .
```

Then `docker compose up -d` from this directory.

## Re-export from the running host

```bash
bash export-images.sh /root/presidio-scan/out/mamori-presidio-en-th-$(date +%Y%m%d).tgz
```
