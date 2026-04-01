#!/bin/bash
#
# Mamori LLC copyright 2026.
#
# Mamori DBPAM port availability pre-check: tests required host ports and exports results to a timestamped CSV.

# CSV output file
CSV_FILE="mamori_port_check_$(date +%Y%m%d_%H%M%S).csv"

# Full list of Mamori ports
declare -A PORTS=(
    [2000]="Mamori local nREPL (java)"
    [3000]="Grafana UI (grafana)"
    [4000]="Erlang/Phoenix (beam.smp)"
    [5000]="Mamori v2 API (java)"
    [4822]="RDP Service (guacd)"
    [5499]="Mamori VDI process (java)"
    [7878]="WireGuard event port (boringtun)"
    [8086]="InfluxDB (influxd)"
    [8088]="InfluxDB (influxd)"
    [8464]="Mamori WebSocket (java)"
    [1122]="SSH Proxy Listener"
    [5432]="Postgres Proxy Listener"
    [1521]="Oracle Proxy Listener"
    [3308]="MySQL Proxy Listener"
    [1433]="SQL Server Proxy Listener"
    [28017]="MongoDB Proxy Listener"
    [1527]="Other JDBC Proxy Listener"
)

# Colors
GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
RESET="\e[0m"

echo -e "\n===================================================="
echo -e " Mamori DBPAM – Port Availability Pre‑Check"
echo -e "====================================================\n"

# Write CSV header
echo "Port,Status,Process,Description" > "$CSV_FILE"

PORT_IN_USE=0

for PORT in "${!PORTS[@]}"; do
    DESCRIPTION="${PORTS[$PORT]}"

    # Check if port is in use
    MATCH=$(ss -tulnp 2>/dev/null | grep ":$PORT ")

    if [[ -n "$MATCH" ]]; then
        PROCESS=$(echo "$MATCH" | awk '{print $NF}')
        echo -e "${RED}[OCCUPIED]${RESET} Port $PORT is in use by: ${YELLOW}$PROCESS${RESET}"
        echo "$PORT,Occupied,\"$PROCESS\",\"$DESCRIPTION\"" >> "$CSV_FILE"
        PORT_IN_USE=1
    else
        echo -e "${GREEN}[AVAILABLE]${RESET} Port $PORT is free"
        echo "$PORT,Available,,\"$DESCRIPTION\"" >> "$CSV_FILE"
    fi
done

echo -e "\n----------------------------------------------------"

if [[ $PORT_IN_USE -eq 1 ]]; then
    echo -e "${RED}Some required ports are already in use.${RESET}"
    echo -e "Please review the remediation suggestions below.\n"
else
    echo -e "${GREEN}All required ports are available. Safe to proceed with deployment.${RESET}\n"
fi

echo -e "CSV report saved to: ${YELLOW}$CSV_FILE${RESET}\n"
