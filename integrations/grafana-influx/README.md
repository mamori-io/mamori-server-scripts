# Grafana / InfluxDB flow check

Mamori writers POST Influx line protocol to the server property `influxdb_write_url`. Hub SQL exposes it as `SYS.SYSSERVERPROPERTIES` (`NAME` / `VAL`). Grafana only reads database `mamori` on `http://localhost:8086` (datasource name `mamori`). It does not collect metrics.

All-in-one InfluxDB listens on `localhost:8086` inside the `mamori` container. On HA, app nodes write to the shared-services host:

```bash
docker exec -it mamori msql "call SET_SERVER_PROPERTY('influxdb_write_url', 'http://<shared-services-host>:8086/write?db=mamori')"
```

An empty `influxdb_write_url` makes Hub and the web app skip the POST. There is no error for that case.

## Healthcheck

From the Mamori host:

```bash
cd integrations/grafana-influx
sudo ./healthcheck.sh
# MAMORI_CONTAINER=mamori FRESH_SECS=180 sudo ./healthcheck.sh
```

Exit 0 only when every required check passes. The script does not change configuration.

| Collector | Must be running | Proof series (last 2 minutes) | Log |
| --- | --- | --- | --- |
| Hub `mamori_fqod` | always | `uptime` | `/opt/mamori/var/log/fqod_metrics.log` (line protocol). Failures: `Unable to write data to influxdb` in `/opt/mamori/var/log/mamori_fqod.log` |
| Web app `dm` | always | `process` where `service=dm` | `/opt/mamori/var/log/dm_health_monitor.log` (`MEMORY USAGE` every 10s). A moving log with no `service=dm` points means the write URL is empty. Failed posts are not logged. |
| Telegraf | when installed (AIO) | `mem` | no log file; `sv status telegraf` and `docker logs` |
| InfluxDB | when installed (AIO) | ping `:8086` | `sv status influxdb` and `docker logs` |
| Grafana | when installed (AIO) | reads only | `/opt/mamori/grafana/data/log/grafana.log` |
| HTTP app proxy | only if `influx.enabled=true` | `process_uptime` (last 5 minutes) | `/opt/mamori/server/http-proxy-<version>/log/proxy-<system>-<instance>.log` |

Telegraf creates database `mamori` with a 7-day retention. It posts to `http://127.0.0.1:8086` and does not use `influxdb_write_url`.

To turn the web app collector on for an all-in-one container:

```bash
docker exec -it mamori msql "call SET_SERVER_PROPERTY('influxdb_write_url', 'http://127.0.0.1:8086/write?db=mamori')"
```

Hub and the web app reload that property without a restart. `process` / `service=dm` should show points within about 10 seconds.
