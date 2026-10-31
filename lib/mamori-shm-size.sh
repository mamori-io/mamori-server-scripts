# Shared memory size for Mamori all-in-one container create.
# Safe to source. Does not write a host state file.
#
# Default from /proc/meminfo MemTotal (integer GB), then clamp to at most 25%
# of RAM and never below 256m:
#   < 4 GB   -> 256m
#   < 8 GB   -> 512m
#   < 16 GB  -> 1g
#   < 32 GB  -> 2g
#   >= 32 GB -> 4g
#
# CLI (install and upgrade): --shm-size 1g | --shm-size=1g | --shmsize=1g
# On success mamori_shm_size_resolve sets MAMORI_SHM_SIZE.
# mamori_shm_size_parse_args leaves non-option arguments in MAMORI_SHM_REMAINING.

# MemTotal in kB. Override in tests by redefining this function.
mamori_shm_size_memtotal_kb() {
    awk '/MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null || true
}

# Print a docker/podman --shm-size value for byte count (1024-based units).
mamori_shm_size_format_bytes() {
    local bytes="$1"
    case "$bytes" in
        268435456) printf '%s' 256m ;;
        536870912) printf '%s' 512m ;;
        1073741824) printf '%s' 1g ;;
        2147483648) printf '%s' 2g ;;
        4294967296) printf '%s' 4g ;;
        *)
            local mb=$((bytes / 1048576))
            if ((mb < 256)); then
                mb=256
            fi
            printf '%sm' "$mb"
            ;;
    esac
}

# Positive integer with an optional docker unit: b, k, kb, m, mb, g, gb.
mamori_shm_size_validate() {
    local size="$1"
    if [[ "$size" =~ ^[1-9][0-9]*([bBkKmMgG]|[kKmMgG][bB])?$ ]]; then
        return 0
    fi
    echo "ERROR: invalid shared memory size '${size}' (expected a positive integer with optional unit b, k, m, or g, for example 1g)" >&2
    return 1
}

# Table from integer GB, then cap at 25% of RAM and floor at 256m.
# Prints the size string. Always returns 0 (missing meminfo uses the floor).
mamori_shm_size_from_memory() {
    local mem_kb mem_gb bytes cap floor_bytes
    mem_kb="$(mamori_shm_size_memtotal_kb)"
    if [[ ! "${mem_kb:-}" =~ ^[0-9]+$ ]]; then
        mem_kb=0
    fi
    mem_gb=$((mem_kb / 1048576))
    if ((mem_gb < 4)); then
        bytes=268435456
    elif ((mem_gb < 8)); then
        bytes=536870912
    elif ((mem_gb < 16)); then
        bytes=1073741824
    elif ((mem_gb < 32)); then
        bytes=2147483648
    else
        bytes=4294967296
    fi
    # 25% of MemTotal: kB * 1024 / 4.
    cap=$((mem_kb * 256))
    floor_bytes=268435456
    if ((bytes > cap)); then
        bytes=$cap
    fi
    if ((bytes < floor_bytes)); then
        bytes=$floor_bytes
    fi
    mamori_shm_size_format_bytes "$bytes"
}

# Consume --shm-size / --shmsize. Unknown options are an error.
# Other arguments are left in MAMORI_SHM_REMAINING.
mamori_shm_size_parse_args() {
    MAMORI_SHM_REMAINING=()
    local seen=0 val
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --shm-size|--shmsize)
                if [[ $# -lt 2 || -z "${2:-}" || "$2" == -* ]]; then
                    echo "ERROR: $1 requires a size (for example 1g)" >&2
                    return 1
                fi
                if [[ "$seen" -eq 1 ]]; then
                    echo "ERROR: --shm-size specified more than once" >&2
                    return 1
                fi
                mamori_shm_size_validate "$2" || return 1
                MAMORI_SHM_SIZE="$2"
                seen=1
                shift 2
                ;;
            --shm-size=*|--shmsize=*)
                val="${1#*=}"
                if [[ -z "$val" ]]; then
                    echo "ERROR: ${1%%=*} requires a size (for example 1g)" >&2
                    return 1
                fi
                if [[ "$seen" -eq 1 ]]; then
                    echo "ERROR: --shm-size specified more than once" >&2
                    return 1
                fi
                mamori_shm_size_validate "$val" || return 1
                MAMORI_SHM_SIZE="$val"
                seen=1
                shift
                ;;
            --)
                shift
                MAMORI_SHM_REMAINING+=("$@")
                break
                ;;
            -*)
                echo "ERROR: unknown option: $1" >&2
                return 1
                ;;
            *)
                MAMORI_SHM_REMAINING+=("$1")
                shift
                ;;
        esac
    done
    return 0
}

# Use MAMORI_SHM_SIZE when already set (CLI or environment); otherwise compute.
mamori_shm_size_resolve() {
    if [[ -n "${MAMORI_SHM_SIZE:-}" ]]; then
        mamori_shm_size_validate "$MAMORI_SHM_SIZE" || return 1
        return 0
    fi
    MAMORI_SHM_SIZE="$(mamori_shm_size_from_memory)"
}
