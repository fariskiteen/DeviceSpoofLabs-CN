#!/system/bin/sh
# Named multi-persona store; one persona active at a time.

PERSONAS_DIR="${PERSONAS_DIR:-${DATA_DIR}/personas}"
ACTIVE_PERSONA_FILE="${ACTIVE_PERSONA_FILE:-${DATA_DIR}/active_persona}"
ACTIVE_SUPER_PERSONA_FILE="${ACTIVE_SUPER_PERSONA_FILE:-${DATA_DIR}/active_super_persona}"
SUPER_CONFIG_DIR="${SUPER_CONFIG_DIR:-${DATA_DIR}/super_config}"
SUPER_FLAG="${SUPER_FLAG:-${DATA_DIR}/super_active}"
MODULE_CONFIG_DIR="${MODULE_CONFIG_DIR:-${MODDIR}/config}"

PERSONA_CONF_FILES="device_identity.conf build_info.conf identifiers.conf custom.conf android_id.conf scope.conf extras.conf"
PERSONA_ACTIVE_CONF_FILES="device_identity.conf build_info.conf identifiers.conf custom.conf extras.conf"

PERSONA_ERROR=""

persona_dir() { echo "${PERSONAS_DIR}/${1}"; }

persona_valid_id() {
    case "$1" in
        '' | *[!a-z0-9_]*) return 1 ;;
    esac
    case "$1" in
        p*) return 0 ;;
        *) return 1 ;;
    esac
}

persona_exists() { [ -d "$(persona_dir "$1")" ]; }

persona_new_id() { printf 'p%s_%s' "$(date +%s)" "$(generate_hex 4)"; }

persona_clean_name() {
    LC_ALL=C tr -d '[:cntrl:]'
}

persona_write_meta() {
    local ID="$1" NAME="$2" CREATED="$3" MODE="${4:-}" DIR
    DIR=$(persona_dir "$ID")
    [ -n "$MODE" ] || MODE=$(persona_get_mode "$ID" 2>/dev/null)
    [ "$MODE" = "super" ] || MODE="standard"
    NAME=$(printf '%s' "$NAME" | persona_clean_name | cut -c1-64)
    [ -n "$NAME" ] || NAME="Persona"
    case "$CREATED" in '' | *[!0-9]*) CREATED=$(date +%s) ;; esac
    {
        printf 'NAME=%s\n' "$NAME"
        printf 'CREATED=%s\n' "$CREATED"
        printf 'MODE=%s\n' "$MODE"
    } > "${DIR}/meta" 2>/dev/null
    chmod 600 "${DIR}/meta" 2>/dev/null
}

persona_get_mode() {
    local ID="$1" M DIR
    M=$(persona_meta_value "$ID" MODE)
    case "$M" in
        super|standard) printf '%s' "$M"; return 0 ;;
    esac
    DIR=$(persona_dir "$ID")
    if grep -q '^SUPER_SPOOF_ENABLED=1$' "${DIR}/extras.conf" 2>/dev/null; then
        printf 'super'
    else
        printf 'standard'
    fi
}

persona_meta_value() {
    local FILE LINE
    FILE="$(persona_dir "$1")/meta"
    [ -f "$FILE" ] || return 0
    while IFS= read -r LINE || [ -n "$LINE" ]; do
        case "$LINE" in
            "$2="*)
                printf '%s' "${LINE#"$2="}"
                return 0
                ;;
        esac
    done < "$FILE"
}

persona_get_name() {
    local NAME
    NAME=$(persona_meta_value "$1" NAME | persona_clean_name)
    [ -n "$NAME" ] || NAME="Persona"
    printf '%s' "$NAME"
}

persona_get_created() {
    persona_meta_value "$1" CREATED
}

persona_field() {
    local ID="$1" FILE="$2" PROP="$3" DIR LINE
    DIR=$(persona_dir "$ID")
    LINE=$(grep -m1 "^ENABLED,${PROP}," "${DIR}/${FILE}" 2>/dev/null) || return 0
    [ -n "$LINE" ] || return 0
    LINE=${LINE#*,}
    printf '%s' "${LINE#*,}"
}

persona_ai_target_count() {
    local N
    N=$(grep -c '^PKG=' "$(persona_dir "$1")/android_id.conf" 2>/dev/null)
    printf '%s' "${N:-0}"
}

persona_ai_enabled() {
    grep -q '^ENABLED$' "$(persona_dir "$1")/android_id.conf" 2>/dev/null
}

persona_scope_mode() {
    local LINE
    LINE=$(grep -m1 '^MODE=' "$(persona_dir "$1")/scope.conf" 2>/dev/null)
    case "${LINE#MODE=}" in
        global) echo "global" ;;
        *) echo "per_app" ;;
    esac
}

persona_scope_target_count() {
    local N
    N=$(grep -c '^PKG=' "$(persona_dir "$1")/scope.conf" 2>/dev/null)
    printf '%s' "${N:-0}"
}

persona_list_ids() {
    [ -d "$PERSONAS_DIR" ] || return 0
    local ID
    {
        for ID in "$PERSONAS_DIR"/*; do
            [ -d "$ID" ] || continue
            ID=${ID##*/}
            persona_valid_id "$ID" && echo "$ID"
        done
    } | sort
}

persona_count() { persona_list_ids | grep -c .; }

persona_regen_identifiers() {
    local DIR="$1" FILE SER IMEI
    FILE="${DIR}/identifiers.conf"
    [ -f "$FILE" ] || return 0
    SER=$(generate_serial)
    IMEI=$(generate_imei)
    PERSONA_GEN_SERIAL="$SER"
    sed -i \
        -e "s|^ENABLED,ro.serialno,.*|ENABLED,ro.serialno,${SER}|" \
        -e "s|^DISABLED,ro.serialno,.*|DISABLED,ro.serialno,${SER}|" \
        -e "s|^ENABLED,persist.radio.imei,.*|ENABLED,persist.radio.imei,${IMEI}|" \
        -e "s|^DISABLED,persist.radio.imei,.*|DISABLED,persist.radio.imei,${IMEI}|" \
        -e "s|^ENABLED,ro.ril.oem.imei,.*|ENABLED,ro.ril.oem.imei,${IMEI}|" \
        -e "s|^DISABLED,ro.ril.oem.imei,.*|DISABLED,ro.ril.oem.imei,${IMEI}|" \
        "$FILE" 2>/dev/null
}

persona_freeze() {
    local DIR="$1" CONF
    for CONF in device_identity.conf build_info.conf identifiers.conf custom.conf extras.conf; do
        [ -f "${DIR}/${CONF}" ] && freeze_config_generators "${DIR}/${CONF}"
    done
}

persona_write_ai_default() {
    local DIR="$1"
    {
        echo "# DeviceSpoofLabs - Android ID (SSAID) spoof config"
        echo "# Managed by the WebUI. value is applied to each PKG's settings_ssaid.xml entry."
        echo "DISABLED"
        echo "VALUE=$(generate_hex 16)"
        echo "USER=0"
    } > "${DIR}/android_id.conf" 2>/dev/null
    chmod 600 "${DIR}/android_id.conf" 2>/dev/null
}

persona_write_scope_default() {
    local DIR="$1" MODE="${2:-standard}"
    if [ "$MODE" = "super" ]; then
        {
            echo "# DeviceSpoofLabs - 超级伪装模式目标应用配置"
            echo "MODE=per_app"
        } > "${DIR}/scope.conf" 2>/dev/null
    elif [ -f "${CONFIG_DIR}/scope.conf" ]; then
        cp "${CONFIG_DIR}/scope.conf" "${DIR}/scope.conf" 2>/dev/null
    else
        {
            echo "# DeviceSpoofLabs - 作用模式与目标应用配置"
            echo "MODE=per_app"
        } > "${DIR}/scope.conf" 2>/dev/null
    fi
    chmod 600 "${DIR}/scope.conf" 2>/dev/null
}

persona_enable_super_extras() {
    local DIR="$1" FILE K
    FILE="${DIR}/extras.conf"
    [ -f "$FILE" ] || return 0
    for K in BUILD_EXTRA_ENABLED GPU_ENABLED MAC_ENABLED DRM_ENABLED UNAME_ENABLED \
             SUPER_SPOOF_ENABLED CPU_SPOOF_ENABLED MEM_STORAGE_ENABLED BATTERY_ENABLED \
             VULKAN_ENABLED SOC_NODE_ENABLED CARRIER_ENABLED BUILD_HOST_ENABLED \
             TZ_LOCALE_ENABLED UPTIME_ENABLED PURITY_ENABLED HIDE_ENV_ENABLED; do
        sed -i "s|^${K}=.*|${K}=1|" "$FILE" 2>/dev/null
    done
    sed -i 's|^BOOT_ID_MODE=.*|BOOT_ID_MODE=fixed|' "$FILE" 2>/dev/null
}

persona_write_extras_default() {
    local DIR="$1" KEY="$2" SER="$3"
    local P_DEV="" P_NAME="" P_BRD="" P_PLT="" P_HW="" P_SMN="" P_SMD="" P_GV="" P_GR="" P_GVN="" P_UR=""
    local P_CP="sd8g3" P_RM="16" P_ST="512" P_BT="5000" P_VV="0x5143" P_VD="0x43050a01" P_SF="Snapdragon" P_SI="603" P_SM="SM8650"
    if device_profile_load "$KEY"; then
        P_DEV="$DEV_PROF_DEVICE"
        P_NAME="$DEV_PROF_NAME"
        P_BRD="$DEV_PROF_BOARD"
        P_PLT="$DEV_PROF_PLATFORM"
        P_HW="$DEV_PROF_HARDWARE"
        P_SMN="$DEV_PROF_SOC_MANUF"
        P_SMD="$DEV_PROF_SOC_MODEL"
        P_GV="$DEV_PROF_GL_VENDOR"
        P_GR="$DEV_PROF_GL_RENDERER"
        P_GVN="$DEV_PROF_GL_VERSION"
        P_UR="$DEV_PROF_UNAME_RELEASE"
        [ -n "$DEV_PROF_CPU_PROFILE" ] && P_CP="$DEV_PROF_CPU_PROFILE"
        [ -n "$DEV_PROF_RAM_GB" ] && P_RM="$DEV_PROF_RAM_GB"
        [ -n "$DEV_PROF_STORAGE_GB" ] && P_ST="$DEV_PROF_STORAGE_GB"
        [ -n "$DEV_PROF_BATTERY_MAH" ] && P_BT="$DEV_PROF_BATTERY_MAH"
        [ -n "$DEV_PROF_VK_VENDOR_ID" ] && P_VV="$DEV_PROF_VK_VENDOR_ID"
        [ -n "$DEV_PROF_VK_DEVICE_ID" ] && P_VD="$DEV_PROF_VK_DEVICE_ID"
        [ -n "$DEV_PROF_SOC_FAMILY" ] && P_SF="$DEV_PROF_SOC_FAMILY"
        [ -n "$DEV_PROF_SOC_ID" ] && P_SI="$DEV_PROF_SOC_ID"
        [ -n "$DEV_PROF_SOC_MACHINE" ] && P_SM="$DEV_PROF_SOC_MACHINE"
    fi
    local P_R
    P_R=$(LC_ALL=C tr -dc '0-9' < /dev/urandom 2>/dev/null | dd bs=1 count=4 2>/dev/null)
    [ -n "$SER" ] || SER=$(generate_serial)
    {
        echo "# DeviceSpoofLabs - Zygisk 进程级增强伪装配置"
        echo "BUILD_EXTRA_ENABLED=1"
        echo "SPOOF_DEVICE=${P_DEV}"
        echo "SPOOF_NAME=${P_NAME}"
        echo "SPOOF_BOARD=${P_BRD}"
        echo "SPOOF_PLATFORM=${P_PLT}"
        echo "SPOOF_HARDWARE=${P_HW}"
        echo "SPOOF_SOC_MANUF=${P_SMN}"
        echo "SPOOF_SOC_MODEL=${P_SMD}"
        echo "SPOOF_BOOT_SERIAL=${SER}"
        echo "SPOOF_SECURITY_PATCH="
        echo "GPU_ENABLED=0"
        echo "GL_VENDOR=${P_GV}"
        echo "GL_RENDERER=${P_GR}"
        echo "GL_VERSION=${P_GVN}"
        echo "MAC_ENABLED=0"
        echo "MAC_ADDR=$(generate_mac)"
        echo "DRM_ENABLED=0"
        echo "DRM_ID=$(generate_hex 64)"
        echo "UNAME_ENABLED=0"
        echo "UNAME_RELEASE=${P_UR}"
        echo "UNAME_VERSION=#1 SMP PREEMPT Thu Jul 18 12:00:00 UTC 2024"
        echo "BOOT_ID_MODE=off"
        echo "BOOT_ID_VALUE=$(generate_uuid)"
        echo "SUPER_SPOOF_ENABLED=0"
        echo "CPU_SPOOF_ENABLED=0"
        echo "CPU_PROFILE=${P_CP}"
        echo "MEM_STORAGE_ENABLED=0"
        echo "RAM_GB=${P_RM}"
        echo "STORAGE_GB=${P_ST}"
        echo "BATTERY_ENABLED=0"
        echo "BATTERY_MAH=${P_BT}"
        echo "VULKAN_ENABLED=0"
        echo "VK_DEVICE_NAME=${P_GR}"
        echo "VK_VENDOR_ID=${P_VV}"
        echo "VK_DEVICE_ID=${P_VD}"
        echo "SOC_NODE_ENABLED=0"
        echo "SOC_FAMILY=${P_SF}"
        echo "SOC_MACHINE=${P_SM}"
        echo "SOC_ID_NUM=${P_SI}"
        echo "SOC_SERIAL=$(generate_hex 8)"
        echo "CARRIER_ENABLED=0"
        echo "CARRIER_NAME=中国移动"
        echo "CARRIER_MCCMNC=46000"
        echo "CARRIER_COUNTRY=cn"
        echo "BASEBAND_VER=MPSS.DE.5.0.c1-00214-${P_BRD}_GEN_PACK-1"
        echo "FAKE_IMEI=$(generate_imei)"
        echo "BUILD_HOST_ENABLED=0"
        echo "SPOOF_HOST=${P_DEV}-build"
        echo "SPOOF_USER=builder"
        echo "TZ_LOCALE_ENABLED=0"
        echo "TIMEZONE_ID=Asia/Shanghai"
        echo "LOCALE_ID=zh-CN"
        echo "UPTIME_ENABLED=0"
        echo "UPTIME_SEC=$((10800 + (1${P_R:-1234} % 43200)))"
        echo "PURITY_ENABLED=0"
        echo "HIDE_ENV_ENABLED=0"
        echo "US_MODE_ENABLED=0"
        echo "US_PRESET=tmobile_la"
    } > "${DIR}/extras.conf" 2>/dev/null
    chmod 600 "${DIR}/extras.conf" 2>/dev/null
}

persona_copy_template() {
    local DIR="$1" CONF="$2"
    if [ -f "${MODULE_CONFIG_DIR}/${CONF}" ]; then
        cp "${MODULE_CONFIG_DIR}/${CONF}" "${DIR}/${CONF}" 2>/dev/null
    elif [ -f "${CONFIG_DIR}/${CONF}" ]; then
        cp "${CONFIG_DIR}/${CONF}" "${DIR}/${CONF}" 2>/dev/null
    else
        : > "${DIR}/${CONF}"
    fi
    chmod 600 "${DIR}/${CONF}" 2>/dev/null
}

persona_seed_defaults() {
    local DIR="$1" KEY="$2" MODE="${3:-standard}" CONF
    PERSONA_GEN_SERIAL=""
    [ -n "$DIR" ] || { PERSONA_ERROR="No persona directory"; return 1; }
    device_load "$KEY" || { PERSONA_ERROR="Unknown device: ${KEY}"; return 1; }
    mkdir -p "$DIR" 2>/dev/null || { PERSONA_ERROR="Could not create persona directory"; return 1; }
    chmod 700 "$DIR" 2>/dev/null

    for CONF in device_identity.conf build_info.conf identifiers.conf custom.conf; do
        persona_copy_template "$DIR" "$CONF"
    done

    device_render "${DIR}/device_identity.conf" && device_render "${DIR}/build_info.conf" \
        || { PERSONA_ERROR="Could not write device values"; return 1; }
    persona_write_ai_default "$DIR"
    persona_write_scope_default "$DIR" "$MODE"
    persona_regen_identifiers "$DIR"
    persona_write_extras_default "$DIR" "$KEY" "$PERSONA_GEN_SERIAL"
    [ "$MODE" = "super" ] && persona_enable_super_extras "$DIR"
    persona_freeze "$DIR"
    return 0
}

persona_create() {
    local NAME="$1" KEY="$2" MODE="${3:-standard}" ID DIR TRY=0
    [ "$MODE" = "super" ] || MODE="standard"
    [ -n "$KEY" ] || KEY=$(device_resolve_key "")
    while :; do
        ID=$(persona_new_id)
        DIR=$(persona_dir "$ID")
        [ -e "$DIR" ] || break
        TRY=$((TRY + 1))
        [ "$TRY" -lt 5 ] || { PERSONA_ERROR="Persona id collision, try again"; return 1; }
    done
    persona_seed_defaults "$DIR" "$KEY" "$MODE" || { rm -rf "$DIR" 2>/dev/null; return 1; }
    persona_write_meta "$ID" "$NAME" "$(date +%s)" "$MODE"
    printf '%s' "$ID"
}

persona_mirror_to_dir() {
    local ID="$1" DST="$2" MODE="${3:-standard}" DIR CONF
    DIR=$(persona_dir "$ID")
    [ -d "$DIR" ] || { PERSONA_ERROR="Persona not found"; return 1; }
    mkdir -p "$DST" 2>/dev/null
    chmod 700 "$DST" 2>/dev/null
    [ -f "${DIR}/scope.conf" ] || persona_write_scope_default "$DIR" "$MODE"
    [ -f "${DIR}/extras.conf" ] || persona_write_extras_default "$DIR" "" "$(grep -m1 '^ENABLED,ro.serialno,' "${DIR}/identifiers.conf" 2>/dev/null | cut -d, -f3)"
    for CONF in $PERSONA_ACTIVE_CONF_FILES; do
        if [ -f "${DIR}/${CONF}" ]; then
            cp "${DIR}/${CONF}" "${DST}/${CONF}" 2>/dev/null
            chmod 600 "${DST}/${CONF}" 2>/dev/null
        fi
    done
    [ -f "${DIR}/android_id.conf" ] && [ "$DST" = "$CONFIG_DIR" ] && {
        cp "${DIR}/android_id.conf" "${DST}/android_id.conf" 2>/dev/null
        chmod 600 "${DST}/android_id.conf" 2>/dev/null
    }
    if [ ! -f "${DST}/scope.conf" ]; then
        {
            echo "# DeviceSpoofLabs - 目标应用配置"
            echo "MODE=per_app"
        } > "${DST}/scope.conf" 2>/dev/null
        chmod 600 "${DST}/scope.conf" 2>/dev/null
    fi
    return 0
}

persona_mirror_to_config() {
    persona_mirror_to_dir "$1" "$CONFIG_DIR" "standard"
}

persona_sync_file_from_config() {
    local NAME="$1" TARGET_MODE="${2:-standard}" ID DIR SRC_DIR
    if [ "$TARGET_MODE" = "super" ]; then
        ID=$(persona_super_active_id) || return 0
        SRC_DIR="$SUPER_CONFIG_DIR"
    else
        ID=$(persona_active_id) || return 0
        SRC_DIR="$CONFIG_DIR"
    fi
    DIR=$(persona_dir "$ID")
    [ -d "$DIR" ] || return 0
    [ -f "${SRC_DIR}/${NAME}" ] || return 0
    cp "${SRC_DIR}/${NAME}" "${DIR}/${NAME}" 2>/dev/null
    chmod 600 "${DIR}/${NAME}" 2>/dev/null
}

persona_read_id_file() {
    local FILE="$1" ID="" LINE N=0
    [ -f "$FILE" ] || return 1
    while IFS= read -r LINE || [ -n "$LINE" ]; do
        ID="${ID}${LINE}"
        N=$((N + 1))
        [ "$N" -le 8 ] || return 1
    done < "$FILE"
    case "$ID" in
        *[!a-z0-9_]*) ID=$(printf '%s' "$ID" | tr -d ' \t\n\r') ;;
    esac
    persona_valid_id "$ID" || return 1
    persona_exists "$ID" || return 1
    echo "$ID"
}

persona_active_id() {
    persona_read_id_file "$ACTIVE_PERSONA_FILE"
}

persona_super_active_id() {
    persona_read_id_file "$ACTIVE_SUPER_PERSONA_FILE"
}

persona_super_activate() {
    local ID="$1" DIR
    persona_valid_id "$ID" && persona_exists "$ID" || { PERSONA_ERROR="No such persona"; return 1; }
    DIR=$(persona_dir "$ID")
    persona_freeze "$DIR"
    persona_mirror_to_dir "$ID" "$SUPER_CONFIG_DIR" "super" || return 1
    printf '%s' "$ID" > "$ACTIVE_SUPER_PERSONA_FILE" 2>/dev/null
    chmod 600 "$ACTIVE_SUPER_PERSONA_FILE" 2>/dev/null
    touch "$SUPER_FLAG" 2>/dev/null
    log "Super persona activated: $ID ($(persona_get_name "$ID"))"
    return 0
}

persona_activate() {
    local ID="$1" DIR PMODE
    persona_valid_id "$ID" && persona_exists "$ID" || { PERSONA_ERROR="No such persona"; return 1; }
    PMODE=$(persona_get_mode "$ID")
    if [ "$PMODE" = "super" ]; then
        persona_super_activate "$ID"
        return $?
    fi
    DIR=$(persona_dir "$ID")

    ensure_backup || { PERSONA_ERROR="Could not capture device backup"; return 1; }
    persona_freeze "$DIR"
    persona_mirror_to_dir "$ID" "$CONFIG_DIR" "standard" || return 1

    printf '%s' "$ID" > "$ACTIVE_PERSONA_FILE" 2>/dev/null
    chmod 600 "$ACTIVE_PERSONA_FILE" 2>/dev/null
    touch "$PERSONA_FLAG" 2>/dev/null
    rm -f "$BOOT_ATTEMPTS_FILE" "$AUTO_DISABLED_FILE" 2>/dev/null
    [ "$(get_scope_mode)" = "global" ] && mark_reboot
    log "Persona activated: $ID ($(persona_get_name "$ID"))"
    return 0
}

persona_super_deactivate() {
    local ID
    ID=$(persona_super_active_id 2>/dev/null)
    rm -f "$SUPER_FLAG" 2>/dev/null
    rm -f "$ACTIVE_SUPER_PERSONA_FILE" 2>/dev/null
    [ -n "$ID" ] && log "Super persona deactivated: $ID"
    return 0
}

persona_deactivate() {
    local MODE="${1:-all}" ID
    if [ "$MODE" = "super" ]; then
        persona_super_deactivate
        return 0
    fi
    ID=$(persona_active_id 2>/dev/null)
    ai_set_enabled 0
    rm -f "$PERSONA_FLAG" 2>/dev/null
    rm -f "$ACTIVE_PERSONA_FILE" 2>/dev/null
    [ "$(get_scope_mode)" = "global" ] && mark_reboot
    [ -n "$ID" ] && log "Persona deactivated: $ID"
    if [ "$MODE" = "all" ]; then
        persona_super_deactivate
    fi
    return 0
}

persona_rename() {
    local ID="$1" NAME="$2"
    persona_valid_id "$ID" && persona_exists "$ID" || { PERSONA_ERROR="No such persona"; return 1; }
    persona_write_meta "$ID" "$NAME" "$(persona_get_created "$ID")"
    log "Persona renamed: $ID"
    return 0
}

persona_delete() {
    local ID="$1"
    persona_valid_id "$ID" && persona_exists "$ID" || { PERSONA_ERROR="No such persona"; return 1; }
    if [ "$(persona_active_id 2>/dev/null)" = "$ID" ]; then
        persona_deactivate standard
    fi
    if [ "$(persona_super_active_id 2>/dev/null)" = "$ID" ]; then
        persona_super_deactivate
    fi
    rm -rf "$(persona_dir "$ID")" 2>/dev/null
    if [ -f "$AUTO_DISABLED_FILE" ] && [ "$(tr -d ' \t\n\r' < "$AUTO_DISABLED_FILE")" = "$ID" ]; then
        rm -f "$AUTO_DISABLED_FILE" 2>/dev/null
    fi
    log "Persona deleted: $ID"
    return 0
}

persona_slug() {
    local S
    S=$(printf '%s' "$1" | LC_ALL=C tr 'A-Z' 'a-z' | LC_ALL=C tr -c 'a-z0-9' '-' | tr -s '-' | cut -c1-40)
    S=${S#-}
    S=${S%-}
    [ -n "$S" ] || S="persona"
    printf '%s' "$S"
}

persona_export() {
    local ID="$1" DEST="$2" DIR NAME FILE TMP CONF LINE BODY NL='
'
    PERSONA_EXPORTED=""
    persona_valid_id "$ID" && persona_exists "$ID" || { PERSONA_ERROR="No such persona: ${ID}"; return 1; }
    DIR=$(persona_dir "$ID")
    NAME=$(persona_get_name "$ID")
    FILE="${DEST}/$(persona_slug "$NAME")-${ID#"${ID%????}"}.persona"
    TMP="${FILE}.tmp.$$"

    {
        echo "# DeviceSpoofLabs persona. Import: WebUI Personas > Import, or devicespooflabs persona-import <file>"
        echo "DSL_PERSONA=1"
        echo "ID=${ID}"
        printf 'NAME=%s\n' "$NAME"
        printf 'CREATED=%s\n' "$(persona_get_created "$ID")"
        printf 'MODE=%s\n' "$(persona_get_mode "$ID")"
        for CONF in $PERSONA_CONF_FILES; do
            echo "[${CONF}]"
            [ -f "${DIR}/${CONF}" ] || continue
            BODY=""
            while IFS= read -r LINE || [ -n "$LINE" ]; do
                BODY="${BODY}${LINE}${NL}"
            done < "${DIR}/${CONF}"
            printf '%s' "$BODY"
        done
    } > "$TMP" 2>/dev/null && mv -f "$TMP" "$FILE" 2>/dev/null || {
        rm -f "$TMP" 2>/dev/null
        PERSONA_ERROR="Could not write ${FILE}"
        return 1
    }

    PERSONA_EXPORTED="$FILE"
    log "Persona exported: $ID -> $FILE"
    return 0
}

persona_import_ai_valid() {
    local LINE STATES=0 VALUES=0
    while IFS= read -r LINE || [ -n "$LINE" ]; do
        case "$LINE" in
            '' | '#'*) ;;
            ENABLED | DISABLED) STATES=$((STATES + 1)) ;;
            VALUE=*) ai_valid_value "${LINE#VALUE=}" || return 1; VALUES=$((VALUES + 1)) ;;
            USER=*) ai_valid_user "${LINE#USER=}" || return 1 ;;
            PKG=*) ai_valid_pkg "${LINE#PKG=}" || return 1 ;;
            *) return 1 ;;
        esac
    done < "$1"
    [ "$STATES" -eq 1 ] && [ "$VALUES" -eq 1 ]
}

persona_import() {
    local FILE="$1" STAGE SRC SIZE LINE CONF DIR SECTION="" HEADER=0 ERR="" ID="" NAME="" CREATED="" REL="" PMODE=""
    PERSONA_IMPORTED_ID=""
    PERSONA_IMPORTED_NAME=""
    PERSONA_IMPORTED_RELEASE=""

    if [ -L "$FILE" ] || [ ! -f "$FILE" ]; then PERSONA_ERROR="Not a regular file: ${FILE}"; return 1; fi
    SIZE=$(wc -c < "$FILE" 2>/dev/null | tr -d ' ')
    case "$SIZE" in '' | *[!0-9]*) PERSONA_ERROR="Could not read ${FILE}"; return 1 ;; esac
    [ "$SIZE" -le 65536 ] || { PERSONA_ERROR="File is larger than 64 KiB"; return 1; }

    mkdir -p "$PERSONAS_DIR" 2>/dev/null
    STAGE="${PERSONAS_DIR}/.import.$$"
    rm -rf "$STAGE" 2>/dev/null
    mkdir "$STAGE" 2>/dev/null || { PERSONA_ERROR="Could not create staging directory"; return 1; }
    chmod 700 "$STAGE" 2>/dev/null
    SRC="${STAGE}/.source"

    tr -d '\r' < "$FILE" > "$SRC" 2>/dev/null || ERR="Could not read ${FILE}"
    if [ -z "$ERR" ] && LC_ALL=C grep -q "$(printf '[\001-\010\013\014\016-\037]')" "$SRC" 2>/dev/null; then
        ERR="File contains control characters"
    fi

    if [ -z "$ERR" ]; then
        while IFS= read -r LINE || [ -n "$LINE" ]; do
            [ "${#LINE}" -le 512 ] || { ERR="A line is longer than 512 bytes"; break; }
            case "$LINE" in
                '['*']')
                    [ "$HEADER" -eq 1 ] || { ERR="Not a DeviceSpoofLabs persona file"; break; }
                    case "$LINE" in
                        '[device_identity.conf]') CONF=device_identity.conf ;;
                        '[build_info.conf]')      CONF=build_info.conf ;;
                        '[identifiers.conf]')     CONF=identifiers.conf ;;
                        '[custom.conf]')          CONF=custom.conf ;;
                        '[android_id.conf]')      CONF=android_id.conf ;;
                        '[scope.conf]')           CONF=scope.conf ;;
                        '[extras.conf]')          CONF=extras.conf ;;
                        *) ERR="Unknown section ${LINE}"; break ;;
                    esac
                    [ ! -e "${STAGE}/${CONF}" ] || { ERR="Duplicate section ${LINE}"; break; }
                    : > "${STAGE}/${CONF}"
                    SECTION=$CONF
                    continue
                    ;;
            esac
            if [ -n "$SECTION" ]; then
                printf '%s\n' "$LINE" >> "${STAGE}/${SECTION}"
                case "${SECTION}:${LINE}" in
                    build_info.conf:ENABLED,ro.build.fingerprint,*:*/*)
                        [ -n "$REL" ] || { REL=${LINE#*:}; REL=${REL%%/*}; }
                        ;;
                esac
                continue
            fi
            case "$LINE" in
                '' | '#'*) ;;
                DSL_PERSONA=1) HEADER=1 ;;
                *)
                    [ "$HEADER" -eq 1 ] || { ERR="Not a DeviceSpoofLabs persona file"; break; }
                    case "$LINE" in
                        ID=*)      ID=${LINE#ID=} ;;
                        NAME=*)    NAME=${LINE#NAME=} ;;
                        CREATED=*) CREATED=${LINE#CREATED=} ;;
                        MODE=*)    PMODE=${LINE#MODE=} ;;
                    esac
                    ;;
            esac
        done < "$SRC"
    fi
    rm -f "$SRC" 2>/dev/null

    if [ -z "$ERR" ]; then
        if [ "$HEADER" -ne 1 ]; then
            ERR="Not a DeviceSpoofLabs persona file"
        elif [ ! -f "${STAGE}/device_identity.conf" ] || [ ! -f "${STAGE}/build_info.conf" ]; then
            ERR="Missing [device_identity.conf] or [build_info.conf] section"
        elif [ -f "${STAGE}/android_id.conf" ] && ! persona_import_ai_valid "${STAGE}/android_id.conf"; then
            ERR="Invalid [android_id.conf] section"
        fi
    fi
    if [ -n "$ERR" ]; then
        rm -rf "$STAGE" 2>/dev/null
        PERSONA_ERROR="$ERR"
        return 1
    fi

    persona_valid_id "$ID" && [ "${#ID}" -le 40 ] || ID=""
    if [ -n "$ID" ] && persona_exists "$ID"; then
        rm -rf "$STAGE" 2>/dev/null
        PERSONA_IMPORTED_ID="$ID"
        PERSONA_IMPORTED_NAME=$(persona_get_name "$ID")
        return 2
    fi
    [ -n "$ID" ] || ID=$(persona_new_id)

    for CONF in identifiers.conf custom.conf; do
        [ -f "${STAGE}/${CONF}" ] || persona_copy_template "$STAGE" "$CONF"
    done
    [ -f "${STAGE}/android_id.conf" ] || persona_write_ai_default "$STAGE"
    [ -f "${STAGE}/scope.conf" ] || persona_write_scope_default "$STAGE"
    [ -f "${STAGE}/extras.conf" ] || persona_write_extras_default "$STAGE" "" ""
    chmod 600 "$STAGE"/*.conf 2>/dev/null

    DIR=$(persona_dir "$ID")
    if [ -e "$DIR" ] || ! mv "$STAGE" "$DIR" 2>/dev/null; then
        rm -rf "$STAGE" 2>/dev/null
        PERSONA_ERROR="Could not save the imported persona"
        return 1
    fi
    case "$CREATED" in '' | *[!0-9]*) CREATED="" ;; esac
    case "$PMODE" in super|standard) ;; *) PMODE="" ;; esac
    persona_write_meta "$ID" "$NAME" "$CREATED" "$PMODE"
    persona_freeze "$DIR"

    PERSONA_IMPORTED_ID="$ID"
    PERSONA_IMPORTED_NAME=$(persona_get_name "$ID")
    case "$REL" in '' | *[!0-9.]*) REL="" ;; esac
    PERSONA_IMPORTED_RELEASE="$REL"
    log "Persona imported: $ID ($PERSONA_IMPORTED_NAME) from $FILE"
    return 0
}

ensure_persona_store() {
    local FIRST_RUN=0
    if [ ! -d "$PERSONAS_DIR" ]; then
        FIRST_RUN=1
        mkdir -p "$PERSONAS_DIR" 2>/dev/null
        chmod 700 "$PERSONAS_DIR" 2>/dev/null
    fi

    [ "$FIRST_RUN" -eq 1 ] || return 0

    if [ ! -f "$PERSONA_FLAG" ] && [ ! -f "$BACKUP_FILE" ]; then
        return 0
    fi
    [ -f "${CONFIG_DIR}/device_identity.conf" ] || return 0

    local ID DIR CONF
    ID=$(persona_new_id)
    DIR=$(persona_dir "$ID")
    mkdir -p "$DIR" 2>/dev/null || return 0
    chmod 700 "$DIR" 2>/dev/null
    for CONF in $PERSONA_CONF_FILES; do
        if [ -f "${CONFIG_DIR}/${CONF}" ]; then
            cp "${CONFIG_DIR}/${CONF}" "${DIR}/${CONF}" 2>/dev/null
            chmod 600 "${DIR}/${CONF}" 2>/dev/null
        fi
    done
    if [ ! -f "${DIR}/android_id.conf" ]; then
        persona_write_ai_default "$DIR"
    fi
    [ -f "${DIR}/scope.conf" ] || persona_write_scope_default "$DIR"
    [ -f "${DIR}/extras.conf" ] || persona_write_extras_default "$DIR" "" ""
    persona_write_meta "$ID" "Default" "$(date +%s)"

    if [ -f "$PERSONA_FLAG" ]; then
        printf '%s' "$ID" > "$ACTIVE_PERSONA_FILE" 2>/dev/null
        chmod 600 "$ACTIVE_PERSONA_FILE" 2>/dev/null
    fi
    log "Migrated existing config into persona $ID (Default)"
    return 0
}
