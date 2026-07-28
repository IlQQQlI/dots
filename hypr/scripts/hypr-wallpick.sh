#!/usr/bin/env bash
set -Eeuo pipefail

# hypr-wallpick
# Select a wallpaper with wofi/rofi, persist it for hyprpaper,
# and apply it immediately through hyprpaper IPC when available.
#
# Usage:
#   hypr-wallpick.sh [wallpaper-directory]
#
# Environment variables:
#   HYPR_WALLPICK_FIT=cover   Wallpaper fit mode.
#   HYPR_WALLPICK_BACKUP=0    Disable hyprpaper.conf backups.

WALL_DIR="${1:-${HOME}/.config/hypr/wallpapers}"
WALL_DIR="${WALL_DIR%/}"
FIT_MODE="${HYPR_WALLPICK_FIT:-cover}"

CFG_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/hypr"
MAIN_CFG="${CFG_DIR}/hyprpaper.conf"
DROP_DIR="${CFG_DIR}/hyprpaper.d"
GEN_CFG="${DROP_DIR}/99-wallpicker.conf"
RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp}"
LOG_FILE="${RUNTIME_DIR}/hyprpaper-wallpick.log"

APP_NAME="hypr-wallpick"
NOTIFY_ICON="preferences-desktop-wallpaper"

has() {
    command -v "$1" >/dev/null 2>&1
}

system_notify() {
    local urgency="$1"
    local title="$2"
    local message="$3"

    has notify-send || return 0

    notify-send \
        --app-name="$APP_NAME" \
        --urgency="$urgency" \
        --icon="$NOTIFY_ICON" \
        "$title" "$message" \
        >/dev/null 2>&1 || true
}

notify_success() {
    system_notify normal "Wallpaper changed" "$1"
}

notify_warning() {
    system_notify normal "Wallpaper saved" "$1"
}

notify_error() {
    system_notify critical "Wallpaper error" "$1"
}

die() {
    printf '%s: %s\n' "$APP_NAME" "$*" >&2
    notify_error "$*"
    exit 1
}

require_environment() {
    has hyprctl || die "hyprctl was not found."
    has hyprpaper || die "hyprpaper was not found."
    has realpath || die "realpath was not found."

    [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]] || \
        die "Run this command inside a Hyprland session without sudo."

    [[ -d "$WALL_DIR" ]] || die "Wallpaper directory not found: $WALL_DIR"

    if ! has wofi && ! has rofi; then
        die "Install wofi or rofi-wayland."
    fi
}

find_wallpapers() {
    find "$WALL_DIR" -maxdepth 1 -type f \
        \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' \
           -o -iname '*.webp' -o -iname '*.bmp' -o -iname '*.jxl' \) \
        -printf '%f\n' | sort -V
}

dmenu_pick() {
    local prompt="$1"

    if has wofi; then
        wofi --dmenu -i -p "$prompt"
    else
        rofi -dmenu -i -p "$prompt"
    fi
}

pick_wallpaper() {
    local files choice selected

    files="$(find_wallpapers)"
    [[ -n "$files" ]] || die "No supported images found in: $WALL_DIR"

    # Cancelling the picker must never overwrite the saved path.
    if ! choice="$(printf '%s\n' "$files" | dmenu_pick 'Wallpaper')"; then
        return 1
    fi
    [[ -n "$choice" ]] || return 1

    selected="$(realpath -e -- "$WALL_DIR/$choice")" || \
        die "Unable to resolve wallpaper path: $WALL_DIR/$choice"

    [[ -f "$selected" ]] || die "Wallpaper file does not exist: $selected"
    [[ -r "$selected" ]] || die "Wallpaper file is not readable: $selected"

    printf '%s\n' "$selected"
}

get_monitors() {
    hyprctl monitors 2>/dev/null | awk '/^Monitor[[:space:]]+/ {print $2}'
}

escape_hyprlang_string() {
    local value="$1"

    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//#/##}"

    printf '%s' "$value"
}

backup_main_config() {
    [[ -f "$MAIN_CFG" ]] || return 0
    [[ "${HYPR_WALLPICK_BACKUP:-1}" != '0' ]] || return 0

    cp -f -- "$MAIN_CFG" \
        "$MAIN_CFG.bak.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
}

ensure_main_config() {
    mkdir -p -- "$CFG_DIR" "$DROP_DIR"

    local desired_source="source = ${GEN_CFG}"
    local body_file new_file
    local changed=0

    body_file="$(mktemp "${CFG_DIR}/.hyprpaper.body.XXXXXX")"
    new_file="$(mktemp "${CFG_DIR}/.hyprpaper.new.XXXXXX")"

    if [[ -f "$MAIN_CFG" ]]; then
        # Remove only directives managed by this script.
        # Preserve all unrelated hyprpaper configuration.
        awk -v managed_source="$desired_source" '
            /^[[:space:]]*#[[:space:]]*managed by hypr-wallpick[[:space:]]*$/ { next }
            /^[[:space:]]*(ipc|splash)[[:space:]]*=/ { next }
            {
                normalized = $0
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", normalized)
                if (normalized == managed_source) next
                print
            }
        ' "$MAIN_CFG" >"$body_file" || true
    fi

    {
        printf '%s\n' '# managed by hypr-wallpick'
        printf '%s\n' 'ipc = true'
        printf '%s\n' 'splash = false'
        printf '\n'

        if [[ -s "$body_file" ]]; then
            cat "$body_file"
            printf '\n'
        fi

        printf '%s\n' "$desired_source"
    } >"$new_file"

    rm -f -- "$body_file"

    if [[ ! -f "$MAIN_CFG" ]] || ! cmp -s -- "$MAIN_CFG" "$new_file"; then
        backup_main_config
        chmod 0644 "$new_file"
        mv -f -- "$new_file" "$MAIN_CFG"
        changed=1
    else
        rm -f -- "$new_file"
    fi

    printf '%s\n' "$changed"
}

write_dropin_config() {
    local image="$1"
    local fit_mode="$2"
    shift 2
    local -a monitor_list=("$@")

    local escaped_image tmp_file monitor
    escaped_image="$(escape_hyprlang_string "$image")"
    tmp_file="$(mktemp "${DROP_DIR}/.99-wallpicker.conf.XXXXXX")"

    {
        printf '# generated by hypr-wallpick on %s\n\n' "$(date -Is)"

        # Fallback for monitors that were disconnected during selection.
        cat <<EOF_CONFIG
wallpaper {
    monitor =
    path = ${escaped_image}
    fit_mode = ${fit_mode}
}

EOF_CONFIG

        for monitor in "${monitor_list[@]}"; do
            cat <<EOF_CONFIG
wallpaper {
    monitor = ${monitor}
    path = ${escaped_image}
    fit_mode = ${fit_mode}
}

EOF_CONFIG
        done
    } >"$tmp_file"

    # Never replace a valid configuration with an empty wallpaper path.
    if [[ -z "$escaped_image" ]] || \
       ! grep -Fq "path = ${escaped_image}" "$tmp_file"; then
        rm -f -- "$tmp_file"
        die "The wallpaper path could not be written to the configuration."
    fi

    chmod 0644 "$tmp_file"
    mv -f -- "$tmp_file" "$GEN_CFG"
}

service_is_active() {
    has systemctl && \
        systemctl --user --quiet is-active hyprpaper.service >/dev/null 2>&1
}

import_hyprland_environment() {
    has systemctl || return 0

    systemctl --user import-environment \
        WAYLAND_DISPLAY HYPRLAND_INSTANCE_SIGNATURE XDG_RUNTIME_DIR \
        >/dev/null 2>&1 || true
}

wait_for_hyprpaper() {
    local attempt

    for attempt in {1..30}; do
        pgrep -u "$UID" -x hyprpaper >/dev/null 2>&1 && return 0
        sleep 0.1
    done

    return 1
}

start_hyprpaper_direct() {
    : >"$LOG_FILE"
    hyprpaper >>"$LOG_FILE" 2>&1 &
    disown || true

    if ! wait_for_hyprpaper; then
        printf '%s: hyprpaper failed to start. Log: %s\n' \
            "$APP_NAME" "$LOG_FILE" >&2
        cat "$LOG_FILE" >&2 || true
        return 1
    fi
}

ensure_hyprpaper_running() {
    pgrep -u "$UID" -x hyprpaper >/dev/null 2>&1 && return 0

    if service_is_active; then
        import_hyprland_environment
        systemctl --user restart hyprpaper.service
        wait_for_hyprpaper || die "hyprpaper.service failed to start."
        return 0
    fi

    start_hyprpaper_direct || \
        die "Unable to start hyprpaper. See: $LOG_FILE"
}

restart_hyprpaper() {
    if service_is_active; then
        import_hyprland_environment
        systemctl --user restart hyprpaper.service || \
            die "Unable to restart hyprpaper.service."
        wait_for_hyprpaper || \
            die "hyprpaper.service stopped immediately after starting."
        return 0
    fi

    pkill -u "$UID" -x hyprpaper >/dev/null 2>&1 || true

    local attempt
    for attempt in {1..20}; do
        pgrep -u "$UID" -x hyprpaper >/dev/null 2>&1 || break
        sleep 0.1
    done

    start_hyprpaper_direct || \
        die "Unable to restart hyprpaper. See: $LOG_FILE"
}

apply_wallpaper_ipc() {
    local monitor="$1"
    local image="$2"
    local fit_mode="$3"

    hyprctl hyprpaper wallpaper \
        "${monitor},${image},${fit_mode}" >/dev/null 2>&1
}

apply_to_all_monitors() {
    local image="$1"
    local fit_mode="$2"
    shift 2
    local -a monitor_list=("$@")
    local monitor failed=0

    for monitor in "${monitor_list[@]}"; do
        if ! apply_wallpaper_ipc "$monitor" "$image" "$fit_mode"; then
            failed=1
        fi
    done

    return "$failed"
}

main() {
    require_environment

    local image monitors_text config_changed
    local -a monitors

    # Cancelling keeps the current wallpaper and configuration unchanged.
    if ! image="$(pick_wallpaper)"; then
        exit 0
    fi

    [[ -n "$image" ]] || die "The selected wallpaper path is empty."

    monitors_text="$(get_monitors)"
    [[ -n "$monitors_text" ]] || die "Hyprland returned no monitors."
    mapfile -t monitors < <(printf '%s\n' "$monitors_text")

    # Persist a valid configuration before touching the running process.
    config_changed="$(ensure_main_config)"
    write_dropin_config "$image" "$FIT_MODE" "${monitors[@]}"

    ensure_hyprpaper_running

    # Restart once if ipc=true was newly written to the main configuration.
    if [[ "$config_changed" == '1' ]]; then
        restart_hyprpaper
    fi

    # Try IPC, restart once on failure, then rely on the saved configuration.
    if ! apply_to_all_monitors "$image" "$FIT_MODE" "${monitors[@]}"; then
        restart_hyprpaper

        if ! apply_to_all_monitors "$image" "$FIT_MODE" "${monitors[@]}"; then
            notify_warning \
                "Saved to configuration. Hyprpaper IPC is unavailable."
            printf '%s: hyprpaper IPC is unavailable; configuration saved to: %s\n' \
                "$APP_NAME" "$GEN_CFG" >&2
            exit 0
        fi
    fi

    notify_success "$(basename -- "$image")"
}

main "$@"
