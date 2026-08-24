# Red Hat–style firewalld backend for Mamori host firewall.
# Safe to source after firewall-common.sh.

MAMORI_FW_FIREWALLD_ZONE="${MAMORI_FW_FIREWALLD_ZONE:-public}"

mamori_fw_firewalld_delete_mamori_rules() {
    local zone="${MAMORI_FW_FIREWALLD_ZONE}"
    local ports rules r
    # Remove ports we manage (re-added from profile)
    ports="$(sudo firewall-cmd --permanent --zone="$zone" --list-ports 2>/dev/null || true)"
    for p in $ports; do
        case "$p" in
            22/tcp|443/tcp|1122/tcp|5432/tcp|1433/tcp|3306/tcp|1521/tcp|28017/tcp|1527/tcp|4822/tcp|8089/tcp|51871/udp)
                sudo firewall-cmd --permanent --zone="$zone" --remove-port="$p" >/dev/null 2>&1 || true
                ;;
        esac
    done
    # Remove Mamori-tagged rich rules
    rules="$(sudo firewall-cmd --permanent --zone="$zone" --list-rich-rules 2>/dev/null || true)"
    while IFS= read -r r; do
        [[ -n "$r" ]] || continue
        if [[ "$r" == *Mamori* ]] || [[ "$r" == *mamori* ]]; then
            sudo firewall-cmd --permanent --zone="$zone" --remove-rich-rule="$r" >/dev/null 2>&1 || true
        fi
    done <<<"$rules"
}

mamori_fw_firewalld_apply() {
    local zone="${MAMORI_FW_FIREWALLD_ZONE}"
    echo "Applying Mamori firewall rules with firewalld (zone=$zone)..."

    if ! systemctl is-active --quiet firewalld 2>/dev/null; then
        sudo systemctl enable --now firewalld
    fi

    mamori_fw_firewalld_delete_mamori_rules

    while IFS='|' read -r proto port comment; do
        [[ -n "$port" ]] || continue
        sudo firewall-cmd --permanent --zone="$zone" --add-port="${port}/${proto}"
    done < <(mamori_fw_expected_port_rules)

    if [[ "${MAMORI_FW_WIREGUARD}" == "1" ]]; then
        # Allow all traffic from WireGuard client CIDR (matches old ufw "allow from CIDR")
        sudo firewall-cmd --permanent --zone="$zone" \
            --add-rich-rule="rule family=\"ipv4\" source address=\"${MAMORI_FW_WG_CIDR}\" accept"
    fi

    sudo firewall-cmd --reload
    echo ""
    echo "Active ports ($zone):"
    sudo firewall-cmd --zone="$zone" --list-ports
    echo "Rich rules ($zone):"
    sudo firewall-cmd --zone="$zone" --list-rich-rules || true
}

mamori_fw_firewalld_has_port() {
    local proto="$1"
    local port="$2"
    local zone="${MAMORI_FW_FIREWALLD_ZONE}"
    local ports
    ports="$(sudo firewall-cmd --zone="$zone" --list-ports 2>/dev/null || true)"
    echo "$ports" | tr ' ' '\n' | grep -qx "${port}/${proto}"
}

mamori_fw_firewalld_has_from_cidr() {
    local cidr="$1"
    local zone="${MAMORI_FW_FIREWALLD_ZONE}"
    local rules
    rules="$(sudo firewall-cmd --zone="$zone" --list-rich-rules 2>/dev/null || true)"
    echo "$rules" | grep -F "source address=\"${cidr}\"" | grep -q accept
}

mamori_fw_firewalld_is_active() {
    sudo firewall-cmd --state 2>/dev/null | grep -qi running
}
