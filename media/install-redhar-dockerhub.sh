#!/bin/bash
#
# Mamori LLC copyright 2026.
#
# Installs Mamori all-in-one on Red Hat–style hosts using Podman: enables the podman socket, pulls the image,
# creates the container with host networking and data volumes, and starts it.

# enable the podman docker socket
sudo systemctl enable --now podman.socket

# pull the mamori docker image
sudo podman pull docker.io/iomamori/mamori-all-in-one:latest

# create the mamori container
sudo podman create \
        --network host \
        --restart always \
        --privileged \
        --log-opt max-size=10m --log-opt max-file=10 \
        -v /run/podman/podman.sock:/var/run/docker.sock \
        -v mamori-var:/opt/mamori/var \
        -v mamori-nginx-conf:/etc/nginx \
        -v mamori-data:/var/lib/postgresql \
        -v mamori-pg-conf:/etc/postgresql \
        -v mamori-influxdb:/opt/mamori/influxdb \
        -v mamori-influxdb-data:/var/lib/influxdb \
        -v mamori-grafana:/opt/mamori/grafana \
        -v /proc:/host/proc:ro \
        -e TZ=`echo $(hash=$(md5sum /etc/localtime | cut -d " " -f 1) ; find /usr/share/zoneinfo -type f -print0 | while read -r -d '' f; do md5sum "$f" | grep "$hash" && break ; done) | rev | cut -d "/" -f 2,1 | rev` \
        --name mamori iomamori/mamori-all-in-one:latest /sbin/my_init

# start the mamori container
sudo podman start mamori
