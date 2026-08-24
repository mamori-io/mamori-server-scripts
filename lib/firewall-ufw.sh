# Ubuntu/Debian ufw backend for Mamori host firewall.
# Safe to source after firewall-common.sh.

mamori_fw_ufw_delete_mamori_rules() {
    # Repeatedly delete lowest-numbered Mamori rule until none remain
    # (ufw renumbers after each delete).
    local i line num
    for i in $(seq 1 100); do
        num=""
        while IFS= read -r line; do
            if [[ "$line" =~ ^\[[[:space:]]*([0-9]+)\] ]] && [[ "$line" == *[Mm]amori* ]]; then
                num="${BASH_REMATCH[1]}"
                break
            fi
        done < <(sudo ufw status numbered 2>/dev/null || true)
        [[ -n "$num" ]] || break
        echo "y" | sudo ufw delete "$num" >/dev/null 2>&1 || break
    done
}

mamori_fw_ufw_apply() {
    echo "Applying Mamori firewall rules with ufw..."

    # Ensure defaults are restrictive when first enabling
    sudo ufw default deny incoming >/dev/null 2>&1 || true
    sudo ufw default allow outgoing >/dev/null 2>&1 || true

    mamori_fw_ufw_delete_mamori_rules

    while IFS='|' read -r proto port comment; do
        [[ -n "$port" ]] || continue
        sudo ufw allow "${port}/${proto}" comment "Mamori ${comment}"
    done < <(mamori_fw_expected_port_rules)

    if [[ "${MAMORI_FW_WIREGUARD}" == "1" ]]; then
        sudo ufw allow from "${MAMORI_FW_WG_CIDR}" comment "Mamori WireGuard clients"
    fi

    sudo ufw --force enable
    echo ""
    sudo ufw status verbose
}

# Return 0 if ufw appears to allow proto/port (best-effort parse of status).
mamori_fw_ufw_has_port() {
    local proto="$1"
    local port="$2"
    local status
    status="$(sudo ufw status 2>/dev/null || true)"
    if echo "$status" | grep -Eiq "^${port}/${proto}[[:space:]]+ALLOW"; then
        return 0
    fi
    if echo "$status" | grep -Eiq "^${port}[[:space:]]+ALLOW"; then
        return 0
    fi
    # Numbered / IPv6 variants: "443/tcp (v6)"
    if echo "$status" | grep -Eiq "^${port}/${proto}[[:space:]]+\(v6\)[[:space:]]+ALLOW"; then
        return 0
    fi
    return 1
}

mamori_fw_ufw_has_from_cidr() {
    local cidr="$1"
    local status
    status="$(sudo ufw status 2>/dev/null || true)"
    echo "$status" | grep -F "$cidr" | grep -qi ALLOW
}

mamori_fw_ufw_is_active() {
    sudo ufw status 2>/dev/null | grep -qi "Status: active"
}
