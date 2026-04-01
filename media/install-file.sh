#!/bin/bash
#
# Mamori LLC copyright 2026.
#
# Initial install of Mamori all-in-one from a local Docker image tarball (mamori_mon_docker.tgz), then creates
# and starts the mamori container with standard volume mounts.

sudo docker image load < mamori_mon_docker.tgz

sudo docker create \
        --network host \
        --restart always \
        --privileged \
        --log-opt max-size=10m --log-opt max-file=10 \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v mamori-var:/opt/mamori/var \
        -v mamori-nginx-conf:/etc/nginx \
        -v mamori-data:/var/lib/postgresql \
        -v mamori-pg-conf:/etc/postgresql \
        -v mamori-influxdb:/opt/mamori/influxdb \
        -v mamori-influxdb-data:/var/lib/influxdb \
        -v mamori-grafana:/opt/mamori/grafana \
        -v /proc:/host/proc:ro \
        -e TZ=`cat /etc/timezone` \
        --name mamori mamori-all-in-one /sbin/my_init

sudo docker start mamori

