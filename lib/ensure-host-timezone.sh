# Resolve / set host timezone for Ubuntu and Red Hat–style systems.
# Safe to source. Used by media/validate-install.sh and install/upgrade scripts.
#
# Effective timezone (for container -e TZ=) is resolved in order:
#   1. timedatectl Timezone
#   2. /etc/timezone (Debian/Ubuntu)
#   3. /etc/localtime symlink target under /usr/share/zoneinfo
#
# On apply: timedatectl set-timezone when available; always best-effort write
# /etc/timezone (helps Ubuntu install scripts); sync /etc/localtime symlink.
#
# On success: HOST_TIMEZONE is set. Returns 0 if a usable zone is known, 1 otherwise.
#
# Environment:
#   HOST_TIMEZONE_FORCE     If set (Region/City), apply without prompting
#   HOST_TIMEZONE_NOPROMPT  If 1, never prompt (check only)

host_timezone_read_file() {
    if [[ -f /etc/timezone ]]; then
        tr -d '[:space:]' </etc/timezone
    fi
}

host_timezone_read_ctl() {
    if command -v timedatectl >/dev/null 2>&1; then
        local tz
        tz="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
        if [[ -z "$tz" ]]; then
            tz="$(timedatectl 2>/dev/null | awk '/Time zone:/ {print $3}')"
        fi
        printf '%s' "$tz"
    fi
}

# Zone name from /etc/localtime -> /usr/share/zoneinfo/...
host_timezone_read_localtime() {
    local target
    if [[ -L /etc/localtime ]]; then
        target="$(readlink -f /etc/localtime 2>/dev/null || readlink /etc/localtime 2>/dev/null || true)"
        if [[ "$target" == */zoneinfo/* ]]; then
            printf '%s' "${target#*/zoneinfo/}"
            return 0
        fi
    fi
    return 1
}

# Print effective IANA zone for container TZ (never empty if UTC fallback).
host_timezone_for_container() {
    local tz
    tz="$(host_timezone_read_ctl)"
    [[ -n "$tz" ]] && { printf '%s' "$tz"; return 0; }
    tz="$(host_timezone_read_file)"
    [[ -n "$tz" ]] && { printf '%s' "$tz"; return 0; }
    tz="$(host_timezone_read_localtime 2>/dev/null || true)"
    [[ -n "$tz" ]] && { printf '%s' "$tz"; return 0; }
    printf '%s' "UTC"
}

# Report current timezone sources (for validate output).
host_timezone_report() {
    local tz_ctl tz_file tz_lt effective
    tz_ctl="$(host_timezone_read_ctl)"
    tz_file="$(host_timezone_read_file)"
    tz_lt="$(host_timezone_read_localtime 2>/dev/null || true)"
    effective="$(host_timezone_for_container)"

    echo "Effective timezone for containers (TZ): $effective"
    [[ -n "$tz_ctl" ]] && echo "  timedatectl: $tz_ctl" || echo "  timedatectl: (unavailable or unset)"
    if [[ -f /etc/timezone ]]; then
        echo "  /etc/timezone: ${tz_file:-"(empty)"}"
    else
        echo "  /etc/timezone: (not present — normal on some Red Hat systems)"
    fi
    [[ -n "$tz_lt" ]] && echo "  /etc/localtime -> $tz_lt" || echo "  /etc/localtime: (not a zoneinfo symlink)"
}

host_timezone_list() {
    local filter="${1:-}"
    if command -v timedatectl >/dev/null 2>&1; then
        if [[ -n "$filter" ]]; then
            timedatectl list-timezones 2>/dev/null | grep -i -- "$filter" || true
        else
            timedatectl list-timezones 2>/dev/null
        fi
        return 0
    fi
    if [[ -d /usr/share/zoneinfo ]]; then
        # shellcheck disable=SC2016
        find /usr/share/zoneinfo -type f ! -path '*/posix/*' ! -path '*/right/*' \
            -printf '%P\n' 2>/dev/null | sort | {
            if [[ -n "$filter" ]]; then
                grep -i -- "$filter" || true
            else
                cat
            fi
        }
        return 0
    fi
    echo "ERROR: cannot list timezones (no timedatectl and no /usr/share/zoneinfo)" >&2
    return 1
}

host_timezone_is_valid() {
    local zone="$1"
    [[ -n "$zone" ]] || return 1
    if command -v timedatectl >/dev/null 2>&1; then
        timedatectl list-timezones 2>/dev/null | grep -qxF "$zone"
        return $?
    fi
    [[ -f "/usr/share/zoneinfo/$zone" ]]
}

host_timezone_apply() {
    local zone="$1"
    if ! host_timezone_is_valid "$zone"; then
        echo "ERROR: Invalid timezone '$zone'." >&2
        echo "List zones: bash validate-install.sh --list-timezones" >&2
        echo "Filter:     bash validate-install.sh --list-timezones Australia" >&2
        return 1
    fi

    if command -v timedatectl >/dev/null 2>&1; then
        if ! sudo timedatectl set-timezone "$zone"; then
            echo "ERROR: timedatectl set-timezone failed" >&2
            return 1
        fi
    elif [[ -f "/usr/share/zoneinfo/$zone" ]]; then
        if ! sudo ln -sfn "/usr/share/zoneinfo/$zone" /etc/localtime; then
            echo "ERROR: failed to update /etc/localtime" >&2
            return 1
        fi
    else
        echo "ERROR: no timedatectl and zoneinfo file missing for $zone" >&2
        return 1
    fi

    # Debian/Ubuntu install scripts historically read /etc/timezone; write when we can.
    if ! printf '%s\n' "$zone" | sudo tee /etc/timezone >/dev/null 2>&1; then
        echo "WARN: could not write /etc/timezone (ok on some systems if timedatectl succeeded)" >&2
    fi

    HOST_TIMEZONE="$zone"
    echo "Timezone set to $zone."
    host_timezone_report
    return 0
}

host_timezone_prompt_and_apply() {
    local suggested default answer zone filter
    suggested="$(host_timezone_for_container)"
    [[ "$suggested" == "UTC" ]] && suggested="$(host_timezone_read_ctl)"
    default="${suggested:-UTC}"

    if [[ ! -t 0 ]]; then
        echo "ERROR: timezone is not configured and stdin is not a TTY." >&2
        echo "Re-run interactively, or: bash validate-install.sh --set-timezone Region/City" >&2
        echo "List zones: bash validate-install.sh --list-timezones" >&2
        return 1
    fi

    echo ""
    echo "Containers need a host timezone (TZ). Current sources:"
    host_timezone_report
    read -r -p "Configure timezone now? [Y/n] " answer
    answer="${answer:-Y}"
    case "$answer" in
        y|Y|yes|YES) ;;
        *)
            echo "Skipped timezone setup."
            return 1
            ;;
    esac

    read -r -p "Filter timezones to list (blank = skip list, e.g. Australia): " filter
    if [[ -n "$filter" ]]; then
        echo "--- Matching timezones ---"
        host_timezone_list "$filter" | head -n 80
        echo "--------------------------"
    fi

    echo "Examples: Australia/Melbourne, America/New_York, UTC"
    read -r -p "Timezone [$default]: " zone
    zone="${zone:-$default}"
    host_timezone_apply "$zone"
}

# Returns 0 when an effective timezone is known (after optional setup).
ensure_host_timezone() {
    local tz_ctl tz_file effective

    if [[ -n "${HOST_TIMEZONE_FORCE:-}" ]]; then
        host_timezone_apply "$HOST_TIMEZONE_FORCE" || return 1
        return 0
    fi

    host_timezone_report
    tz_ctl="$(host_timezone_read_ctl)"
    tz_file="$(host_timezone_read_file)"
    effective="$(host_timezone_for_container)"

    # Prefer timedatectl or /etc/timezone; UTC-only from fallback with no ctl/file is weak on fresh hosts
    if [[ -n "$tz_ctl" || -n "$tz_file" ]]; then
        HOST_TIMEZONE="${tz_ctl:-$tz_file}"
        if [[ -n "$tz_ctl" && -n "$tz_file" && "$tz_ctl" != "$tz_file" ]]; then
            echo "WARN: timedatectl ($tz_ctl) differs from /etc/timezone ($tz_file)"
            if [[ "${HOST_TIMEZONE_NOPROMPT:-0}" != "1" && -t 0 ]]; then
                local answer
                read -r -p "Sync both to timedatectl value '$tz_ctl'? [Y/n] " answer
                answer="${answer:-Y}"
                case "$answer" in
                    y|Y|yes|YES)
                        host_timezone_apply "$tz_ctl" || return 1
                        return 0
                        ;;
                esac
                read -r -p "Enter a timezone to set (blank keeps current effective $effective): " answer
                if [[ -n "$answer" ]]; then
                    host_timezone_apply "$answer" || return 1
                fi
            fi
        fi
        return 0
    fi

    # Have /etc/localtime zone but no timedatectl/file — still usable for containers
    if [[ "$effective" != "UTC" ]] || host_timezone_read_localtime >/dev/null 2>&1; then
        local lt
        lt="$(host_timezone_read_localtime 2>/dev/null || true)"
        if [[ -n "$lt" ]]; then
            HOST_TIMEZONE="$lt"
            if [[ "${HOST_TIMEZONE_NOPROMPT:-0}" != "1" && -t 0 ]]; then
                local answer
                echo "Using /etc/localtime zone: $lt (no /etc/timezone / timedatectl name)."
                read -r -p "Persist this with timedatectl + /etc/timezone? [Y/n] " answer
                answer="${answer:-Y}"
                case "$answer" in
                    y|Y|yes|YES)
                        host_timezone_apply "$lt" || return 1
                        ;;
                esac
            fi
            return 0
        fi
    fi

    if [[ "${HOST_TIMEZONE_NOPROMPT:-0}" == "1" ]]; then
        echo "ERROR: no usable host timezone (timedatectl / /etc/timezone / localtime)" >&2
        return 1
    fi

    host_timezone_prompt_and_apply
}
