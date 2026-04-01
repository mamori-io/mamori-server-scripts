#!/bin/bash
#
# Mamori LLC copyright 2026.
#
# Upgrades a running Mamori all-in-one deployment by pulling iomamori/mamori-all-in-one:latest from Docker Hub
# and recreating the container with preserved volumes.

# clean up any system logs that are filling the disk
sudo journalctl --vacuum-size=10M

# tag the current mamori image so we can delete is later
sudo docker image tag iomamori/mamori-all-in-one mamori-old

sudo docker pull iomamori/mamori-all-in-one:latest
RC=$?
if [ $RC -ne 0 ]; then
        echo "docker load failed :("
        exit $RC
fi

NOW=`date +%s`
sudo docker stop mamori
sudo docker rename mamori mamori-$NOW

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

sudo docker rm mamori-$NOW
sudo docker rmi `sudo docker image ls -a | grep mamori-old | awk '{print $3}'`
