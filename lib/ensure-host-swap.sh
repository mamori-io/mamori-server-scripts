# Ensure swap is present, or offer to create a 4GB /swapfile.
# Safe to source. Used by media/validate-install.sh.
#
# Swap is recommended but optional (some cloud providers disallow it).
# Sets HOST_SWAP_ACTIVE=0|1. Returns 0 unless an attempted setup fails.
#
# Environment:
#   HOST_SWAP_FORCE       If 1, create 4GB swap without prompting when missing
#   HOST_SWAP_NOPROMPT    If 1, never prompt (check/warn only)
#   HOST_SWAP_SIZE_GB     Swapfile size in GB (default: 4)
#   HOST_SWAP_FILE        Path for new swapfile (default: /swapfile)

HOST_SWAP_SIZE_GB="${HOST_SWAP_SIZE_GB:-4}"
HOST_SWAP_FILE="${HOST_SWAP_FILE:-/swapfile}"

host_swap_is_active() {
    local swap_show swap_proc swap_total_kb
    swap_show="$(swapon --show --noheadings 2>/dev/null || true)"
    swap_proc="$(awk 'NR>1 {print}' /proc/swaps 2>/dev/null || true)"
    swap_total_kb="$(awk '/SwapTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
    [[ -n "$swap_show" || -n "$swap_proc" ]] && [[ "${swap_total_kb:-0}" -gt 0 ]]
}

host_swap_status_info() {
    local swap_show swap_total_kb
    swap_show="$(swapon --show --noheadings 2>/dev/null || true)"
    swap_total_kb="$(awk '/SwapTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
    echo "Swap is active (${swap_total_kb} kB)"
    [[ -n "$swap_show" ]] && echo "swapon: $swap_show"
}

host_swap_create() {
    local size_gb="${HOST_SWAP_SIZE_GB}"
    local path="${HOST_SWAP_FILE}"

    if host_swap_is_active; then
        echo "Swap already active; nothing to do."
        HOST_SWAP_ACTIVE=1
        return 0
    fi

    if [[ -e "$path" ]]; then
        echo "ERROR: $path already exists. Remove it or set HOST_SWAP_FILE to another path." >&2
        return 1
    fi

    echo "Creating ${size_gb}GB swap at $path (requires sudo)..."
    if ! sudo fallocate -l "${size_gb}G" "$path"; then
        echo "ERROR: fallocate failed (provider may disallow swap)." >&2
        return 1
    fi
    if ! sudo chmod 600 "$path"; then
        echo "ERROR: chmod 600 $path failed" >&2
        return 1
    fi
    if ! sudo mkswap "$path"; then
        echo "ERROR: mkswap failed" >&2
        sudo rm -f "$path" 2>/dev/null || true
        return 1
    fi
    if ! sudo swapon "$path"; then
        echo "ERROR: swapon failed (provider may disallow swap)." >&2
        sudo rm -f "$path" 2>/dev/null || true
        return 1
    fi

    if ! grep -qE "^${path}[[:space:]]" /etc/fstab 2>/dev/null; then
        if ! echo "$path none swap sw 0 0" | sudo tee -a /etc/fstab >/dev/null; then
            echo "WARN: swap is active but failed to append $path to /etc/fstab" >&2
        else
            echo "Added $path to /etc/fstab for reboot persistence."
        fi
    fi

    HOST_SWAP_ACTIVE=1
    echo "Swap created and enabled (${size_gb}GB at $path)."
    return 0
}

host_swap_prompt_and_create() {
    local answer
    if [[ ! -t 0 ]]; then
        echo "WARN: No active swap. Install docs recommend ${HOST_SWAP_SIZE_GB}GB when allowed."
        echo "      Re-run interactively or: bash validate-install.sh --add-swap"
        HOST_SWAP_ACTIVE=0
        return 0
    fi

    echo ""
    echo "No active swap. Install docs recommend ${HOST_SWAP_SIZE_GB}GB when the provider allows it."
    read -r -p "Create ${HOST_SWAP_SIZE_GB}GB swap at ${HOST_SWAP_FILE} now? [y/N] " answer
    answer="${answer:-N}"
    case "$answer" in
        y|Y|yes|YES)
            host_swap_create || return 1
            ;;
        *)
            echo "Skipped swap setup (optional)."
            HOST_SWAP_ACTIVE=0
            ;;
    esac
    return 0
}

# Returns 0 unless an attempted swap setup fails hard.
ensure_host_swap() {
    if host_swap_is_active; then
        HOST_SWAP_ACTIVE=1
        host_swap_status_info
        return 0
    fi

    HOST_SWAP_ACTIVE=0

    if [[ "${HOST_SWAP_FORCE:-0}" == "1" ]]; then
        host_swap_create
        return $?
    fi

    if [[ "${HOST_SWAP_NOPROMPT:-0}" == "1" ]]; then
        echo "WARN: No active swap (optional — some providers disallow swap)."
        echo "      If permitted: fallocate -l ${HOST_SWAP_SIZE_GB}G ${HOST_SWAP_FILE} && chmod 600 ${HOST_SWAP_FILE} && mkswap ${HOST_SWAP_FILE} && swapon ${HOST_SWAP_FILE}"
        echo "      echo '${HOST_SWAP_FILE} none swap sw 0 0' | tee -a /etc/fstab"
        return 0
    fi

    host_swap_prompt_and_create
}
