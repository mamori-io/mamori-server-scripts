#!/bin/sh
#
# Mamori LLC copyright 2026.
#
# Writes a live Java heap dump (jmap .hprof) for the Mamori process inside the mamori container.

exec docker exec -it mamori bash -c "/opt/mamori/jdk/bin/jmap -dump:live,format=b,file=/opt/mamori/var/mamori_fqod.hprof \`cat /opt/mamori/var/run/mamori_fqod.pid\`"
