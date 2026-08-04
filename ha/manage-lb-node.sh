#!/bin/bash
#
# Mamori LLC copyright 2026.
#
# Register, unregister, enable, or disable an HA app node on the load balancer.
# Updates /etc/hosts, nginx upstream hub, and HAProxy listen backends.
# Run on the gateway / load-balancer host.
#

set -euo pipefail

HOSTS_FILE="${HOSTS_FILE:-/etc/hosts}"
NGINX_LB="${NGINX_LB:-/etc/nginx/sites-available/load-balancer}"
HAPROXY_CFG="${HAPROXY_CFG:-/etc/haproxy/haproxy.cfg}"
BACKUP_DIR="${BACKUP_DIR:-/opt/mamori/lb-backup}"

ACTION=""
NAME=""
IP=""
SERVER_ID=""
DRY_RUN=0
NO_RELOAD=0

usage() {
    cat <<'EOF'
Usage: manage-lb-node.sh --register|--unregister|--enable|--disable [options]

Manage an HA app node in the gateway load balancer (hosts + nginx + HAProxy).

Actions (exactly one required):
  --register             Add node to hosts, nginx upstream hub, and all HAProxy listens
  --unregister           Remove node from nginx, HAProxy, and hosts aliases
  --enable               Mark node up (remove nginx 'down' / HAProxy 'disabled')
  --disable              Mark node down without removing (nginx 'down', HAProxy 'disabled')

Options:
  --name <hostname>      Backend hostname used in configs (e.g. m3) [required]
  --ip <address>         Node IP reachable from the gateway [--register required]
  --server-id <id>       HAProxy server id (default: mamorihubN when --name is mN)
  --dry-run              Print planned changes; do not write or reload
  --no-reload            Write configs and run haproxy -c; skip nginx -t and service reloads
  --hosts <file>         Hosts file (default: /etc/hosts)
  --nginx <file>         nginx load-balancer site
  --haproxy <file>       HAProxy config
  --backup-dir <dir>     Backup directory (default: /opt/mamori/lb-backup)
  -h, --help             Show this help

Examples:
  bash manage-lb-node.sh --register --name m3 --ip 10.240.0.6
  bash manage-lb-node.sh --disable --name m3
  bash manage-lb-node.sh --enable --name m3
  bash manage-lb-node.sh --unregister --name m3
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --register|--unregister|--enable|--disable)
            if [[ -n "$ACTION" ]]; then
                echo "ERROR: only one action allowed" >&2
                exit 1
            fi
            ACTION="${1#--}"
            ;;
        --name)
            shift
            NAME="${1:-}"
            [[ -n "$NAME" ]] || { echo "Missing value for --name" >&2; exit 1; }
            ;;
        --ip)
            shift
            IP="${1:-}"
            [[ -n "$IP" ]] || { echo "Missing value for --ip" >&2; exit 1; }
            ;;
        --server-id)
            shift
            SERVER_ID="${1:-}"
            [[ -n "$SERVER_ID" ]] || { echo "Missing value for --server-id" >&2; exit 1; }
            ;;
        --dry-run)
            DRY_RUN=1
            ;;
        --no-reload)
            NO_RELOAD=1
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
        --backup-dir)
            shift
            BACKUP_DIR="${1:-}"
            [[ -n "$BACKUP_DIR" ]] || { echo "Missing value for --backup-dir" >&2; exit 1; }
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

if [[ -z "$ACTION" ]]; then
    echo "ERROR: specify --register, --unregister, --enable, or --disable" >&2
    usage >&2
    exit 1
fi
if [[ -z "$NAME" ]]; then
    echo "ERROR: --name is required" >&2
    exit 1
fi
if [[ "$ACTION" == "register" && -z "$IP" ]]; then
    echo "ERROR: --ip is required for --register" >&2
    exit 1
fi

if [[ -z "$SERVER_ID" ]]; then
    if [[ "$NAME" =~ ^m([0-9]+)$ ]]; then
        SERVER_ID="mamorihub${BASH_REMATCH[1]}"
    elif [[ "$ACTION" == "register" ]]; then
        echo "ERROR: --server-id is required when --name is not mN (e.g. m3)" >&2
        exit 1
    else
        # enable/disable/unregister: discover from haproxy if possible
        SERVER_ID=""
    fi
fi

for f in "$HOSTS_FILE" "$NGINX_LB" "$HAPROXY_CFG"; do
    if [[ ! -f "$f" ]]; then
        echo "ERROR: file not found: $f" >&2
        exit 1
    fi
done

export ACTION NAME IP SERVER_ID DRY_RUN NO_RELOAD HOSTS_FILE NGINX_LB HAPROXY_CFG BACKUP_DIR

python3 <<'PY'
import os
import re
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

action = os.environ["ACTION"]
name = os.environ["NAME"]
ip = os.environ.get("IP") or ""
server_id = os.environ.get("SERVER_ID") or ""
dry_run = os.environ.get("DRY_RUN") == "1"
no_reload = os.environ.get("NO_RELOAD") == "1"
hosts_path = Path(os.environ["HOSTS_FILE"])
nginx_path = Path(os.environ["NGINX_LB"])
haproxy_path = Path(os.environ["HAPROXY_CFG"])
backup_dir = Path(os.environ["BACKUP_DIR"])

hosts_text = hosts_path.read_text(errors="replace")
nginx_text = nginx_path.read_text(errors="replace")
haproxy_text = haproxy_path.read_text(errors="replace")

changes = []


def die(msg):
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def discover_server_id(cfg: str, host: str) -> str:
    """Find HAProxy server id for host:port lines."""
    ids = []
    for line in cfg.splitlines():
        body = line.strip().lstrip("#").strip()
        m = re.search(rf"\bserver\s+(\S+)\s+{re.escape(host)}:", body)
        if m:
            ids.append(m.group(1))
    if not ids:
        return ""
    # prefer mamorihubN style; else first unique
    for i in ids:
        if i.startswith("mamorihub"):
            return i
    return ids[0]


if not server_id:
    server_id = discover_server_id(haproxy_text, name)
    if action != "register" and not server_id:
        # allow enable/disable/unregister using name only for nginx/hosts;
        # haproxy still needs an id for clean edits — try deriving from mN
        m = re.fullmatch(r"m([0-9]+)", name)
        if m:
            server_id = f"mamorihub{m.group(1)}"
        else:
            die(f"could not determine --server-id for host {name}; pass --server-id")


def sandbox_alias(host, text):
    """If peers use name.sandbox in hosts, keep that pattern."""
    if re.search(r"\b\S+\.sandbox\b", text):
        return f"{host}.sandbox"
    return None


def update_hosts(text: str) -> str:
    alias = sandbox_alias(name, text)
    aliases = [name] + ([alias] if alias else [])
    lines = text.splitlines(keepends=True)
    out = []
    found = False
    for line in lines:
        code = line.split("#", 1)[0]
        parts = code.split()
        if len(parts) >= 2 and name in parts[1:]:
            found = True
            if action == "unregister":
                changes.append(f"hosts: remove line for {name}")
                continue
            comment = ""
            if "#" in line:
                comment = " #" + line.split("#", 1)[1].rstrip("\n")
                # drop trailing newline from comment handling
                if line.endswith("\n"):
                    pass
            # rebuild aliases keeping extras except outdated ip line
            extra = [a for a in parts[1:] if a not in aliases]
            new_aliases = aliases + extra
            new_ip = ip if action == "register" and ip else parts[0]
            if action == "register" and parts[0] != ip:
                changes.append(f"hosts: update {name} {parts[0]} -> {ip}")
            elif action == "register":
                changes.append(f"hosts: keep {name} -> {ip}")
            else:
                # enable/disable: leave hosts alone
                out.append(line)
                continue
            comment_part = ""
            if "#" in line:
                comment_part = " #" + line.split("#", 1)[1].rstrip("\r\n")
            out.append(f"{new_ip} {' '.join(new_aliases)}{comment_part}\n")
            continue
        out.append(line)
    if action == "register" and not found:
        alias_str = " ".join(aliases)
        changes.append(f"hosts: add {ip} {alias_str}")
        if out and not out[-1].endswith("\n"):
            out[-1] = out[-1] + "\n"
        out.append(f"{ip} {alias_str}\n")
    elif action == "unregister" and not found:
        changes.append(f"hosts: {name} not present (ok)")
    elif action in ("enable", "disable"):
        changes.append(f"hosts: unchanged for {action}")
    return "".join(out)


def update_nginx(text: str) -> str:
    m = re.search(r"upstream\s+hub\s*\{([^}]*)\}", text, re.S)
    if not m:
        die("nginx: upstream hub { ... } not found")
    body = m.group(1)
    server_re = re.compile(
        rf"^(\s*)server\s+{re.escape(name)}:(\d+)(.*)$", re.M
    )

    def rebuild(new_body: str) -> str:
        return text[: m.start(1)] + new_body + text[m.end(1) :]

    match = server_re.search(body)
    if action == "register":
        if match:
            indent, port, rest = match.group(1), match.group(2), match.group(3)
            # ensure not down for register (register implies active)
            rest2 = re.sub(r"\s*\bdown\b", "", rest)
            if not rest2.strip().endswith(";"):
                # keep existing terminator
                pass
            new_line = f"{indent}server {name}:{port}{rest2}"
            if "down" in rest.split():
                changes.append(f"nginx: re-enable server {name}:{port}")
            else:
                changes.append(f"nginx: already present server {name}:{port}")
            new_body = body[: match.start()] + new_line + body[match.end() :]
            return rebuild(new_body)
        # append after last server line — match its indentation
        indent = "    "
        last = None
        for line in body.splitlines():
            sm = re.match(r"^(\s*)server\s+", line)
            if sm:
                indent = sm.group(1)
                last = line
        new_line = f"{indent}server {name}:80;"
        changes.append(f"nginx: add {new_line.strip()}")
        if last is not None:
            idx = body.rfind(last)
            insert_at = idx + len(last)
            if insert_at < len(body) and body[insert_at] == "\n":
                insert_at += 1
                new_body = body[:insert_at] + new_line + "\n" + body[insert_at:]
            else:
                new_body = body[:insert_at] + "\n" + new_line + body[insert_at:]
        else:
            new_body = body.rstrip("\n") + "\n" + new_line + "\n"
        return rebuild(new_body)

    if action == "unregister":
        if not match:
            changes.append(f"nginx: {name} not present (ok)")
            return text
        # remove whole line
        start = match.start()
        end = match.end()
        # eat trailing newline
        if end < len(body) and body[end] == "\n":
            end += 1
        changes.append(f"nginx: remove server {name}")
        return rebuild(body[:start] + body[end:])

    if action == "disable":
        if not match:
            die(f"nginx: server {name} not found (register first)")
        indent, port, rest = match.group(1), match.group(2), match.group(3)
        if re.search(r"\bdown\b", rest):
            changes.append(f"nginx: {name} already down")
            return text
        # insert down before trailing ;
        if rest.rstrip().endswith(";"):
            rest_core = rest.rstrip()[:-1]
            new_rest = rest_core + " down;"
        else:
            new_rest = rest + " down"
        changes.append(f"nginx: mark {name}:{port} down")
        new_line = f"{indent}server {name}:{port}{new_rest}"
        return rebuild(body[: match.start()] + new_line + body[match.end() :])

    if action == "enable":
        if not match:
            die(f"nginx: server {name} not found (register first)")
        indent, port, rest = match.group(1), match.group(2), match.group(3)
        if not re.search(r"\bdown\b", rest):
            changes.append(f"nginx: {name} already up")
            return text
        new_rest = re.sub(r"\s*\bdown\b", "", rest)
        changes.append(f"nginx: mark {name}:{port} up")
        new_line = f"{indent}server {name}:{port}{new_rest}"
        return rebuild(body[: match.start()] + new_line + body[match.end() :])

    return text


def iter_listen_blocks(text: str):
    """Yield (start, end, block_text) for each listen block."""
    lines = text.splitlines(keepends=True)
    i = 0
    while i < len(lines):
        if re.match(r"^\s*listen\s+\S+", lines[i]):
            start = i
            i += 1
            while i < len(lines):
                if re.match(r"^(listen|frontend|backend|global|defaults)\s", lines[i].strip()):
                    break
                i += 1
            yield start, i, "".join(lines[start:i])
        else:
            i += 1


def first_hub_server_line(block: str):
    """Return (indent, server_id, host, port, flags) for first active mamorihub* or any server line."""
    for line in block.splitlines():
        if line.strip().startswith("#"):
            continue
        m = re.match(
            r"^(\s*)server\s+(\S+)\s+([^:\s]+):(\d+)\s*(.*)$", line.rstrip()
        )
        if not m:
            continue
        return m.group(1), m.group(2), m.group(3), m.group(4), m.group(5).strip()
    return None


def update_haproxy(text: str) -> str:
    lines = text.splitlines(keepends=True)
    # Work block by block via reconstruction
    blocks = list(iter_listen_blocks(text))
    if not blocks and action == "register":
        die("haproxy: no listen blocks found")

    replacements = []
    enable_disable_hits = 0

    for start, end, block in blocks:
        ref = first_hub_server_line(block)
        if ref is None:
            continue

        block_lines = block.splitlines(keepends=True)
        new_block_lines = []
        touched = False

        tmpl = first_hub_server_line(block)
        assert tmpl is not None
        t_indent, _, _, t_port, t_flags = tmpl
        base_flags = re.sub(r"\s*\bdisabled\b", "", t_flags).strip()
        listen_label = block.splitlines()[0].strip()

        def make_server_line(disabled=False):
            fl = base_flags
            if disabled and not re.search(r"\bdisabled\b", fl):
                fl = (fl + " disabled").strip()
            line = f"{t_indent}server  {server_id}      {name}:{t_port}"
            if fl:
                line += f" {fl}"
            return line + "\n"

        def is_ours(body):
            return bool(
                re.match(rf"#?\s*server\s+{re.escape(server_id)}\s+", body)
                or re.match(rf"#?\s*server\s+\S+\s+{re.escape(name)}:", body)
            )

        if action == "register":
            for bl in block_lines:
                body = bl.strip()
                if is_ours(body):
                    if not touched:
                        new_block_lines.append(make_server_line(disabled=False))
                        changes.append(
                            f"haproxy[{listen_label}]: upsert {server_id} {name}:{t_port}"
                        )
                        touched = True
                    else:
                        changes.append(
                            f"haproxy: drop duplicate line for {server_id}/{name}"
                        )
                    continue
                new_block_lines.append(bl)
            if not touched:
                insert_idx = None
                for idx, bl in enumerate(new_block_lines):
                    if re.search(r"\bserver\s+", bl) and not bl.strip().startswith("#"):
                        insert_idx = idx
                line = make_server_line(disabled=False)
                if insert_idx is None:
                    new_block_lines.append(line)
                else:
                    new_block_lines.insert(insert_idx + 1, line)
                changes.append(
                    f"haproxy[{listen_label}]: add {server_id} {name}:{t_port}"
                )
            replacements.append((start, end, "".join(new_block_lines)))
            continue

        if action == "unregister":
            for bl in block_lines:
                body = bl.strip()
                if is_ours(body):
                    changes.append(
                        f"haproxy[{listen_label}]: remove {server_id}/{name}"
                    )
                    touched = True
                    continue
                new_block_lines.append(bl)
            if not touched:
                continue
            replacements.append((start, end, "".join(new_block_lines)))
            continue

        if action in ("enable", "disable"):
            for bl in block_lines:
                body = bl.strip()
                if not is_ours(body):
                    new_block_lines.append(bl)
                    continue
                raw = bl
                if body.startswith("#"):
                    mindent = re.match(r"^(\s*)#\s?", bl)
                    content = bl[mindent.end() :] if mindent else bl.lstrip("#")
                    raw = content if content.endswith("\n") else content + "\n"
                    changes.append(f"haproxy[{listen_label}]: uncomment {server_id}")
                m = re.match(
                    r"^(\s*)server\s+(\S+)\s+([^:\s]+):(\d+)\s*(.*)$",
                    raw.rstrip("\n"),
                )
                if not m:
                    new_block_lines.append(raw)
                    continue
                ind, sid, host, port, fl = m.groups()
                fl = fl.strip()
                if action == "disable":
                    if re.search(r"\bdisabled\b", fl):
                        changes.append(
                            f"haproxy[{listen_label}]: {sid} already disabled"
                        )
                    else:
                        fl = (fl + " disabled").strip()
                        changes.append(f"haproxy[{listen_label}]: disable {sid}")
                else:
                    if re.search(r"\bdisabled\b", fl):
                        fl = re.sub(r"\s*\bdisabled\b", "", fl).strip()
                        changes.append(f"haproxy[{listen_label}]: enable {sid}")
                    else:
                        changes.append(
                            f"haproxy[{listen_label}]: {sid} already enabled"
                        )
                new_line = f"{ind}server  {sid}      {host}:{port}"
                if fl:
                    new_line += f" {fl}"
                new_line += "\n"
                new_block_lines.append(new_line)
                touched = True
                enable_disable_hits += 1
            if touched:
                replacements.append((start, end, "".join(new_block_lines)))
            continue

    if action in ("enable", "disable") and enable_disable_hits == 0:
        die(f"haproxy: {server_id}/{name} not found in any listen block (register first)")

    if not replacements:
        return text

    # Apply from end to start
    for start, end, new_block in sorted(replacements, key=lambda x: x[0], reverse=True):
        lines[start:end] = [new_block]
    return "".join(lines)


new_hosts = update_hosts(hosts_text)
new_nginx = update_nginx(nginx_text)
new_haproxy = update_haproxy(haproxy_text)

print(f"Action: {action}")
print(f"Node:   {name}" + (f" ({server_id})" if server_id else ""))
if ip:
    print(f"IP:     {ip}")
print("Planned changes:")
for c in changes:
    print(f"  - {c}")

if dry_run:
    print("Dry-run: no files written, no reload.")
    sys.exit(0)

# Skip write if nothing effectively changed
if new_hosts == hosts_text and new_nginx == nginx_text and new_haproxy == haproxy_text:
    print("No file content changes needed.")
    sys.exit(0)

ts = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
backup_dir.mkdir(parents=True, exist_ok=True)
for src, label in (
    (hosts_path, "hosts"),
    (nginx_path, "nginx-load-balancer"),
    (haproxy_path, "haproxy.cfg"),
):
    dst = backup_dir / f"{label}.{ts}"
    shutil.copy2(src, dst)
    print(f"Backup: {dst}")

hosts_path.write_text(new_hosts)
nginx_path.write_text(new_nginx)
haproxy_path.write_text(new_haproxy)
print("Wrote hosts, nginx, and haproxy configs.")

# validate / reload
def restore():
    for src, label in (
        (hosts_path, "hosts"),
        (nginx_path, "nginx-load-balancer"),
        (haproxy_path, "haproxy.cfg"),
    ):
        shutil.copy2(backup_dir / f"{label}.{ts}", src)

try:
    subprocess.run(["haproxy", "-c", "-f", str(haproxy_path)], check=True)
except FileNotFoundError:
    print("WARNING: haproxy binary not found; skipped haproxy -c")
except subprocess.CalledProcessError:
    restore()
    die("haproxy -c failed; restored backups")

if no_reload:
    print("Wrote configs; skipped nginx -t and service reloads (--no-reload).")
    print("Done.")
    sys.exit(0)

try:
    subprocess.run(["nginx", "-t"], check=True)
except subprocess.CalledProcessError:
    restore()
    die("nginx -t failed; restored backups")

subprocess.run(["nginx", "-s", "reload"], check=True)
print("nginx reloaded")

rc = subprocess.run(["systemctl", "reload", "haproxy"])
if rc.returncode != 0:
    rc = subprocess.run(["service", "haproxy", "reload"])
if rc.returncode != 0:
    die("failed to reload haproxy")
print("haproxy reloaded")
print("Done.")
PY
