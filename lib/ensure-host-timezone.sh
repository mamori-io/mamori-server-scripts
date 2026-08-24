# Ensure /etc/timezone is set (and preferably matches timedatectl).
# Safe to source. Used by media/validate-install.sh.
#
# On success: HOST_TIMEZONE is set to the configured zone.
# Returns 0 if timezone is usable, 1 otherwise.
#
# Environment:
#   HOST_TIMEZONE_FORCE   If set (Region/City), apply without prompting
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
        echo "ERROR: Invalid timezone '$zone'. List with: timedatectl list-timezones" >&2
        return 1
    fi

    if command -v timedatectl >/dev/null 2>&1; then
        if ! sudo timedatectl set-timezone "$zone"; then
            echo "ERROR: timedatectl set-timezone failed" >&2
            return 1
        fi
    fi

    if ! printf '%s\n' "$zone" | sudo tee /etc/timezone >/dev/null; then
        echo "ERROR: failed to write /etc/timezone" >&2
        return 1
    fi

    # Keep /etc/localtime consistent when timedatectl is unavailable
    if [[ ! -L /etc/localtime && -f "/usr/share/zoneinfo/$zone" ]]; then
        sudo ln -sf "/usr/share/zoneinfo/$zone" /etc/localtime 2>/dev/null || true
    fi

    HOST_TIMEZONE="$zone"
    echo "Timezone set to $zone (/etc/timezone + timedatectl when available)."
    return 0
}

host_timezone_prompt_and_apply() {
    local suggested current default answer zone
    suggested="$(host_timezone_read_ctl)"
    current="$(host_timezone_read_file)"
    default="${suggested:-${current:-UTC}}"

    if [[ ! -t 0 ]]; then
        echo "ERROR: /etc/timezone is not set and stdin is not a TTY." >&2
        echo "Re-run interactively, or: bash validate-install.sh --set-timezone Region/City" >&2
        return 1
    fi

    echo ""
    echo "Portal containers use TZ from /etc/timezone (install docs require it)."
    if [[ -n "$suggested" ]]; then
        echo "Current timedatectl timezone: $suggested"
    fi
    read -r -p "Configure timezone now? [Y/n] " answer
    answer="${answer:-Y}"
    case "$answer" in
        y|Y|yes|YES) ;;
        *)
            echo "Skipped timezone setup."
            return 1
            ;;
    esac

    echo "Examples: Australia/Melbourne, America/New_York, UTC"
    echo "List all: timedatectl list-timezones"
    read -r -p "Timezone [$default]: " zone
    zone="${zone:-$default}"
    host_timezone_apply "$zone"
}

# Returns 0 when /etc/timezone is non-empty (and optionally matches timedatectl).
ensure_host_timezone() {
    local tz_file tz_ctl

    if [[ -n "${HOST_TIMEZONE_FORCE:-}" ]]; then
        host_timezone_apply "$HOST_TIMEZONE_FORCE" || return 1
        return 0
    fi

    tz_file="$(host_timezone_read_file)"
    tz_ctl="$(host_timezone_read_ctl)"

    if [[ -n "$tz_file" ]]; then
        HOST_TIMEZONE="$tz_file"
        if [[ -n "$tz_ctl" && "$tz_file" != "$tz_ctl" ]]; then
            echo "WARN: /etc/timezone ($tz_file) does not match timedatectl ($tz_ctl)"
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
                read -r -p "Or enter a timezone to set both (blank keeps mismatch): " answer
                if [[ -n "$answer" ]]; then
                    host_timezone_apply "$answer" || return 1
                    return 0
                fi
            fi
        fi
        return 0
    fi

    # Missing /etc/timezone
    if [[ "${HOST_TIMEZONE_NOPROMPT:-0}" == "1" ]]; then
        echo "ERROR: /etc/timezone is missing or empty" >&2
        return 1
    fi

    if [[ -n "$tz_ctl" && -t 0 ]]; then
        local answer
        echo "/etc/timezone is missing (timedatectl reports: $tz_ctl)."
        read -r -p "Write timedatectl value to /etc/timezone and continue? [Y/n] " answer
        answer="${answer:-Y}"
        case "$answer" in
            y|Y|yes|YES)
                host_timezone_apply "$tz_ctl" && return 0
                ;;
        esac
    fi

    host_timezone_prompt_and_apply
}
