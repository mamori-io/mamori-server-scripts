#!/bin/bash
#
# Mamori LLC copyright 2026.
#
# Initial install of Mamori all-in-one by pulling iomamori/mamori-all-in-one:latest from Docker Hub, then
# creating and starting the mamori container with standard volume mounts.

sudo docker pull iomamori/mamori-all-in-one:latest
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
        --name mamori iomamori/mamori-all-in-one:latest /sbin/my_init

sudo docker start mamori

