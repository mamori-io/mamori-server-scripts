#!/bin/sh
#
# Mamori LLC copyright 2026.
#
# Captures a Java thread stack dump (jstack) from the Mamori process inside the mamori container.

exec docker exec -it mamori bash -c "/opt/mamori/jdk/bin/jstack -l \`cat /opt/mamori/var/run/mamori_fqod.pid\`"
