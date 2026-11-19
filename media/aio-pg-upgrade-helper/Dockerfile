# Helper image for in-place AIO PostgreSQL 14 -> 18 pg_upgrade.
# Debian-layout binaries for both majors; not a Mamori runtime image.
FROM ubuntu:noble

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl wget gnupg lsb-release \
    && echo "deb http://apt.postgresql.org/pub/repos/apt/ $(lsb_release -cs)-pgdg main" \
        > /etc/apt/sources.list.d/pgdg.list \
    && wget -qO - https://www.postgresql.org/media/keys/ACCC4CF8.asc \
        | gpg --dearmor -o /etc/apt/trusted.gpg.d/pgdg.gpg \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        postgresql-14 postgresql-contrib-14 \
        postgresql-18 postgresql-contrib-18 \
        ssl-cert \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

COPY migrate.sh /usr/local/bin/mamori-aio-pg-migrate
RUN chmod +x /usr/local/bin/mamori-aio-pg-migrate

ENTRYPOINT ["/usr/local/bin/mamori-aio-pg-migrate"]
