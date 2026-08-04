#!/bin/bash
#
# Mamori LLC copyright 2026.
#
# Dump load-balancer config summary and the existing HA app-node list.
# Run on the gateway / load-balancer host.
#

set -euo pipefail

HOSTS_FILE="${HOSTS_FILE:-/etc/hosts}"
NGINX_LB="${NGINX_LB:-/etc/nginx/sites-available/load-balancer}"
HAPROXY_CFG="${HAPROXY_CFG:-/etc/haproxy/haproxy.cfg}"
FULL=0

usage() {
    cat <<'EOF'
Usage: dump-lb-config.sh [options]

Show nginx upstream hubs, HAProxy backend servers, and matching /etc/hosts
entries for the Mamori load balancer.

Options:
  --full                 Also print the full HAProxy config file
  --hosts <file>         Hosts file (default: /etc/hosts)
  --nginx <file>         nginx load-balancer site (default: sites-available/load-balancer)
  --haproxy <file>       HAProxy config (default: /etc/haproxy/haproxy.cfg)
  -h, --help             Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --full)
            FULL=1
            ;;
        --hosts)
            shift
            HOSTS_FILE="${1:-}"
            [[ -n "$HOSTS_FILE" ]] || { echo "Missing value for --hosts" >&2; exit 1; }
            ;;
        --nginx)
            shift
            NGINX_LB="${1:-}"
            [[ -n "$NGINX_LB" ]] || { echo "Missing value for --nginx" >&2; exit 1; }
            ;;
        --haproxy)
            shift
            HAPROXY_CFG="${1:-}"
            [[ -n "$HAPROXY_CFG" ]] || { echo "Missing value for --haproxy" >&2; exit 1; }
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
    shift
done

python3 - "$HOSTS_FILE" "$NGINX_LB" "$HAPROXY_CFG" "$FULL" <<'PY'
import re
import sys
from pathlib import Path

hosts_path, nginx_path, haproxy_path, full = sys.argv[1:5]
full = full == "1"

def read(path):
    p = Path(path)
    if not p.is_file():
        return None
    return p.read_text(errors="replace")

print("=== Load balancer node dump ===")
print(f"hosts:   {hosts_path}")
print(f"nginx:   {nginx_path}")
print(f"haproxy: {haproxy_path}")
print()

nginx = read(nginx_path)
haproxy = read(haproxy_path)
hosts = read(hosts_path)

# --- nginx upstream hub ---
print("--- nginx upstream hub ---")
names = set()
if nginx is None:
    print(f"(missing: {nginx_path})")
else:
    m = re.search(r"upstream\s+hub\s*\{([^}]*)\}", nginx, re.S)
    if not m:
        print("(no 'upstream hub' block found)")
    else:
        for line in m.group(1).splitlines():
            s = line.strip()
            if not s or s.startswith("#"):
                continue
            print(f"  {s}")
            sm = re.match(r"server\s+([^:;/\s]+)", s)
            if sm:
                names.add(sm.group(1))

print()

# --- haproxy servers ---
print("--- haproxy listen backends ---")
if haproxy is None:
    print(f"(missing: {haproxy_path})")
else:
    current = None
    for raw in haproxy.splitlines():
        line = raw.rstrip()
        stripped = line.strip()
        if re.match(r"^listen\s+\S+", stripped):
            current = stripped.split(None, 1)[1]
            print(f"\n[{current}]")
            continue
        if current is None:
            continue
        # blank line or next top-level section ends listen visually; still print servers
        if re.match(r"^(listen|frontend|backend|global|defaults)\s", stripped):
            current = stripped.split(None, 1)[1] if stripped.startswith("listen") else None
            if stripped.startswith("listen"):
                print(f"\n[{current}]")
            continue
        # server lines (active or commented)
        if re.search(r"\bserver\s+\S+", stripped):
            print(f"  {stripped}")
            sm = re.search(r"\bserver\s+(\S+)\s+(\S+)", stripped.lstrip("#").strip())
            if sm:
                addr = sm.group(2)
                host = addr.split(":")[0]
                names.add(host)

print()

# --- hosts ---
print("--- /etc/hosts (matching backend names) ---")
if hosts is None:
    print(f"(missing: {hosts_path})")
else:
    shown = False
    for raw in hosts.splitlines():
        # strip comments for matching but show original-ish
        code = raw.split("#", 1)[0]
        parts = code.split()
        if len(parts) < 2:
            continue
        aliases = parts[1:]
        if any(a in names or any(a.startswith(n + ".") for n in names) for a in aliases):
            print(f"  {raw}")
            shown = True
        elif names and any(n in aliases for n in names):
            print(f"  {raw}")
            shown = True
    if not shown and names:
        # also show lines whose first alias looks like mN if present in names
        for raw in hosts.splitlines():
            code = raw.split("#", 1)[0]
            parts = code.split()
            if len(parts) >= 2 and parts[1] in names:
                print(f"  {raw}")
                shown = True
    if not shown:
        if names:
            print(f"  (no hosts entries for: {', '.join(sorted(names))})")
        else:
            print("  (no backend names discovered)")

print()
print("--- node summary ---")
if not names:
    print("  (none)")
else:
    # resolve from hosts
    ip_by_name = {}
    if hosts:
        for raw in hosts.splitlines():
            code = raw.split("#", 1)[0]
            parts = code.split()
            if len(parts) < 2:
                continue
            ip, aliases = parts[0], parts[1:]
            for a in aliases:
                ip_by_name[a] = ip
    for n in sorted(names):
        ip = ip_by_name.get(n, "?")
        # status from nginx / haproxy
        nginx_st = "absent"
        if nginx:
            m = re.search(r"upstream\s+hub\s*\{([^}]*)\}", nginx, re.S)
            if m:
                for line in m.group(1).splitlines():
                    s = line.strip()
                    if s.startswith("#"):
                        continue
                    if re.match(rf"server\s+{re.escape(n)}(:|\s)", s):
                        nginx_st = "down" if re.search(r"\bdown\b", s) else "up"
                        break
        hap_active = 0
        hap_disabled = 0
        hap_commented = 0
        if haproxy:
            for raw in haproxy.splitlines():
                stripped = raw.strip()
                body = stripped.lstrip("#").strip()
                if not re.search(rf"\bserver\s+\S+\s+{re.escape(n)}:", body):
                    continue
                if stripped.startswith("#"):
                    hap_commented += 1
                elif re.search(r"\bdisabled\b", body):
                    hap_disabled += 1
                else:
                    hap_active += 1
        if hap_active and not hap_disabled and not hap_commented:
            hap_st = "up"
        elif hap_disabled and not hap_active:
            hap_st = "disabled"
        elif hap_commented and not hap_active and not hap_disabled:
            hap_st = "commented"
        elif hap_active or hap_disabled or hap_commented:
            hap_st = f"mixed(active={hap_active},disabled={hap_disabled},commented={hap_commented})"
        else:
            hap_st = "absent"
        print(f"  {n:20} ip={ip:18} nginx={nginx_st:8} haproxy={hap_st}")

if full:
    print()
    print(f"=== full HAProxy config ({haproxy_path}) ===")
    if haproxy is None:
        print(f"(missing: {haproxy_path})")
    else:
        print(haproxy, end="" if haproxy.endswith("\n") else "\n")
PY
