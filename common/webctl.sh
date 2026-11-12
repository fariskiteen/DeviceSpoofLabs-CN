#!/system/bin/sh
# Non-interactive control layer for the WebUI bridge and devicespooflabs CLI.

if [ "$1" = "--b64" ]; then
    shift
    command -v base64 >/dev/null 2>&1 || { echo "ERROR: base64 not found" >&2; exit 127; }
    {
        RC=$(
            {
                {
                    { "$0" "$@" 3>&- 4>&- 5>&-; echo "$?" >&3; } |
                        { B=$(base64) && echo "b64:$B" >&4; }
                } 2>&1 | { B=$(base64) && [ -n "$B" ] && echo "b64:$B" >&5; }
            } 3>&1
        )
    } 4>&1 5>&2
    exit "${RC:-1}"
fi

SCRIPT_DIR="${0%/*}"
MODDIR="${MODDIR:-/data/adb/modules/devicespooflab}"

[ -f "${SCRIPT_DIR}/state.sh" ] && . "${SCRIPT_DIR}/state.sh"
[ -f "${SCRIPT_DIR}/utils.sh" ] && . "${SCRIPT_DIR}/utils.sh"
[ -f "${SCRIPT_DIR}/value_resolver.sh" ] && . "${SCRIPT_DIR}/value_resolver.sh"
[ -f "${SCRIPT_DIR}/android_id.sh" ] && . "${SCRIPT_DIR}/android_id.sh"
[ -f "${SCRIPT_DIR}/personas.sh" ] && . "${SCRIPT_DIR}/personas.sh"
[ -f "${SCRIPT_DIR}/devices.sh" ] && . "${SCRIPT_DIR}/devices.sh"

case "$(type ensure_persistent_state 2>/dev/null)" in *function*) ensure_persistent_state ;; esac
case "$(type ensure_persona_store 2>/dev/null)" in *function*) ensure_persona_store ;; esac

MODULE_ID="devicespooflab"
MODULE_NAME="DeviceSpoofLabs"

KSUWEBUI_PKG="io.github.a13e300.ksuwebui"
KSUWEBUI_ACTIVITY="io.github.a13e300.ksuwebui/.WebUIActivity"
KSUWEBUI_APK_URL="https://github.com/5ec1cff/KsuWebUIStandalone/releases/download/v1.0/KsuWebUI-1.0-34-release.apk"
KSUWEBUI_APK_SHA256="a99e9a66c79d94db7cc5cf0c12607df1790215423e3d917c937dc16093c8135d"
KSUWEBUI_APK_SIZE="1703779"
KSUWEBUI_RELEASE_PAGE="https://github.com/5ec1cff/KsuWebUIStandalone/releases/latest"

WEBUIX_PKG="com.dergoogler.mmrl.wx"
WEBUIX_ACTIVITY="com.dergoogler.mmrl.wx/.ui.webui.WebUIActivity"
WEBUIX_ACTIVITY_OLD="com.dergoogler.mmrl.wx/.ui.activity.webui.WebUIActivity"

PERSONA_EXPORT_DIR="${PERSONA_EXPORT_DIR:-/storage/emulated/0/Download/DeviceSpoofLabs}"

__JSON_CTRL=$(printf '\001-\037\t')
__JSON_TAB=${__JSON_CTRL#"${__JSON_CTRL%?}"}
__JSON_CTRL=${__JSON_CTRL%?}
__JSON_NL='
'

json_set() {
    local S="$1" OUT="" HEAD REST
    case $S in
        *[\\\"$__JSON_CTRL]*) ;;
        *) JSTR=\"$S\"; return 0 ;;
    esac
    [ "${#S}" -le 4096 ] || S=$(printf '%s' "$S" | dd bs=4096 count=1 2>/dev/null)
    while :; do
        HEAD=${S%%[\\\"$__JSON_CTRL]*}
        OUT="${OUT}${HEAD}"
        S=${S#"$HEAD"}
        case $S in
            '')                           break ;;
            \\*)                          OUT="${OUT}\\\\" ;;
            \"*)                          OUT="${OUT}\\\"" ;;
            "$__JSON_NL"*|"$__JSON_TAB"*) OUT="${OUT} " ;;
        esac
        REST=${S#?}
        [ "$REST" != "$S" ] || break
        S=$REST
    done
    JSTR=\"$OUT\"
}

json_str() {
    json_set "$1"
    printf '%s' "$JSTR"
}

emit_ok() {
    printf '{"ok":true,"message":%s}\n' "$(json_str "$1")"
}

emit_ok_reboot() {
    printf '{"ok":true,"reboot_required":true,"message":%s}\n' "$(json_str "$1")"
}

emit_error() {
    printf '{"ok":false,"message":%s}\n' "$(json_str "$1")"
}

get_version() {
    local LINE
    VERSION=""
    if [ -f "${MODDIR}/module.prop" ]; then
        while IFS= read -r LINE || [ -n "$LINE" ]; do
            case $LINE in
                version=*) VERSION=${LINE#version=}; break ;;
            esac
        done < "${MODDIR}/module.prop"
    fi
    [ -n "$VERSION" ] || VERSION="v4.0-cn"
}

is_persona_active() {
    [ -f "$PERSONA_FLAG" ]
}

is_super_active() {
    [ -f "$SUPER_FLAG" ]
}

is_unsafe_props_enabled() {
    [ -f "${CONFIG_DIR}/allow_unsafe_props" ] && return 0
    [ "$(getprop persist.devicespooflab.allow_unsafe 2>/dev/null)" = "1" ] && return 0
    return 1
}

get_scope_mode() {
    local LINE
    [ -f "${CONFIG_DIR}/scope.conf" ] || { echo "global"; return; }
    LINE=$(grep -m1 '^MODE=' "${CONFIG_DIR}/scope.conf" 2>/dev/null)
    case "${LINE#MODE=}" in
        global) echo "global" ;;
        *) echo "per_app" ;;
    esac
}

_read_scope_targets_from() {
    local FILE="$1" LINE PKG
    [ -f "$FILE" ] || return 0
    grep '^PKG=' "$FILE" 2>/dev/null | while IFS= read -r LINE; do
        PKG=${LINE#PKG=}
        ai_valid_pkg "$PKG" && echo "$PKG"
    done
}

get_scope_targets() {
    _read_scope_targets_from "${CONFIG_DIR}/scope.conf"
}

get_super_scope_targets() {
    _read_scope_targets_from "${SUPER_CONFIG_DIR}/scope.conf"
}

scope_target_count() {
    local N
    N=$(get_scope_targets | grep -c . 2>/dev/null)
    printf '%s' "${N:-0}"
}

super_scope_target_count() {
    local N
    N=$(get_super_scope_targets | grep -c . 2>/dev/null)
    printf '%s' "${N:-0}"
}

zygisk_so_present() {
    [ -f "${MODDIR}/zygisk/arm64-v8a.so" ] || [ -f "${MODDIR}/zygisk/armeabi-v7a.so" ]
}

mark_reboot() {
    touch "$REBOOT_PENDING" 2>/dev/null
}

backup_value() {
    [ -f "$BACKUP_FILE" ] || return 0
    local LINE
    LINE=$(grep -m1 "^$1=" "$BACKUP_FILE" 2>/dev/null)
    [ -n "$LINE" ] && printf '%s' "${LINE#*=}"
}

configured_value() {
    local CONF FILE LINE
    for CONF in device_identity build_info identifiers custom; do
        FILE="${CONFIG_DIR}/${CONF}.conf"
        [ -f "$FILE" ] || continue
        LINE=$(grep -m1 "^ENABLED,$1," "$FILE" 2>/dev/null)
        if [ -n "$LINE" ]; then
            LINE=${LINE#*,}
            printf '%s' "${LINE#*,}"
            return 0
        fi
    done
}

extras_value() {
    local KEY="$1" DIR="${2:-$CONFIG_DIR}" FILE LINE
    FILE="${DIR}/extras.conf"
    [ -f "$FILE" ] || return 0
    LINE=$(grep -m1 "^${KEY}=" "$FILE" 2>/dev/null)
    [ -n "$LINE" ] && printf '%s' "${LINE#*=}"
}

super_prop_value() {
    local KEY="$1" FILE LINE
    for FILE in device_identity.conf build_info.conf; do
        [ -f "${SUPER_CONFIG_DIR}/${FILE}" ] || continue
        LINE=$(grep -m1 "^ENABLED,${KEY}," "${SUPER_CONFIG_DIR}/${FILE}" 2>/dev/null)
        if [ -n "$LINE" ]; then
            LINE=${LINE#*,}
            printf '%s' "${LINE#*,}"
            return 0
        fi
    done
}

create_backup() {
    mkdir -p "$(dirname "$BACKUP_FILE")" "$CONFIG_DIR" 2>/dev/null
    {
        echo "# DeviceSpoofLabs - Original Device Backup"
        echo "# Generated: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "# DO NOT EDIT - This is your restore point"
        echo ""
        local CONF FILE LINE PROP SEEN=" "
        for CONF in device_identity build_info identifiers; do
            FILE="${CONFIG_DIR}/${CONF}.conf"
            [ -f "$FILE" ] || continue
            while IFS= read -r LINE || [ -n "$LINE" ]; do
                case "$LINE" in ENABLED,*) ;; *) continue ;; esac
                PROP=${LINE#*,}
                PROP=${PROP%%,*}
                [ -n "$PROP" ] || continue
                case "$SEEN" in *" $PROP "*) continue ;; esac
                SEEN="${SEEN}${PROP} "
                echo "${PROP}=$(getprop "$PROP")"
            done < "$FILE"
        done
    } > "$BACKUP_FILE"
    chmod 600 "$BACKUP_FILE" 2>/dev/null
    log "Backup created at $BACKUP_FILE"
}

ensure_backup() {
    [ -f "$BACKUP_FILE" ] || create_backup
}

restore_backup() {
    [ -f "$BACKUP_FILE" ] || { log "ERROR: no backup to restore"; return 1; }

    local KEY VALUE CONF FILE
    while IFS='=' read -r KEY VALUE; do
        [ -z "$KEY" ] && continue
        case "$KEY" in '#'*) continue ;; esac

        VALUE=$(echo "$VALUE" | tr -d '"')

        for CONF in device_identity build_info identifiers; do
            FILE="${CONFIG_DIR}/${CONF}.conf"
            [ -f "$FILE" ] || continue
            if grep -q ",$KEY," "$FILE" 2>/dev/null; then
                sed -i "s|^ENABLED,$KEY,.*|ENABLED,$KEY,$VALUE|" "$FILE"
                sed -i "s|^DISABLED,$KEY,.*|ENABLED,$KEY,$VALUE|" "$FILE"
            fi
        done
    done < "$BACKUP_FILE"

    log "Backup restored"
}

reboot_runtime() {
    svc power reboot 2>/dev/null || /system/bin/reboot
}

valid_config_name() {
    case "$1" in
        device_identity.conf|build_info.conf|identifiers.conf|custom.conf|scope.conf|extras.conf) return 0 ;;
        *) return 1 ;;
    esac
}

emit_status_val() {
    local JK JL JV JO JC
    json_set "$1"; JK=$JSTR
    json_set "$2"; JL=$JSTR
    json_set "$4"; JV=$JSTR
    json_set "$5"; JO=$JSTR
    json_set "$6"; JC=$JSTR
    [ "$VAL_FIRST" -eq 1 ] || STATUS_JSON="${STATUS_JSON},"
    VAL_FIRST=0
    STATUS_JSON="${STATUS_JSON}{\"key\":${JK},\"label\":${JL},\"live\":${JV},\"original\":${JO},\"configured\":${JC},\"spoofable\":${3}}"
}

cmd_status() {
    if [ -z "$PERSONA_FLAG" ] || [ -z "$CONFIG_DIR" ]; then
        emit_error "模块状态不可用（state.sh 未加载）"
        return 1
    fi

    get_version

    local PERSONA=false SUPER_ACT=false UNSAFE=false REBOOT=false BACKUP=false AUTO_OFF=false ZYGISK_OK=false SUPER_ON=false
    local ACTIVE_ID ACTIVE_NAME ACTIVE_SUPER_ID ACTIVE_SUPER_NAME AUTO_OFF_ID AUTO_OFF_NAME JV STATUS_JSON SCOPE_MODE SCOPE_CNT SUPER_CNT
    local SP_MODEL="" SP_CPU="" SP_RAM="" SP_STOR="" SP_GPU="" SP_US="false"
    is_persona_active && PERSONA=true
    is_super_active && SUPER_ACT=true
    is_unsafe_props_enabled && UNSAFE=true
    [ -f "$REBOOT_PENDING" ] && REBOOT=true
    [ -f "$BACKUP_FILE" ] && BACKUP=true
    zygisk_so_present && ZYGISK_OK=true
    if [ "$SUPER_ACT" = true ] || [ "$(extras_value SUPER_SPOOF_ENABLED)" = "1" ]; then
        SUPER_ON=true
    fi
    SCOPE_MODE=$(get_scope_mode)
    SCOPE_CNT=$(scope_target_count)
    SUPER_CNT=$(super_scope_target_count)
    ACTIVE_ID=$(persona_active_id 2>/dev/null)
    [ -n "$ACTIVE_ID" ] && ACTIVE_NAME=$(persona_get_name "$ACTIVE_ID")
    ACTIVE_SUPER_ID=$(persona_super_active_id 2>/dev/null)
    [ -n "$ACTIVE_SUPER_ID" ] && ACTIVE_SUPER_NAME=$(persona_get_name "$ACTIVE_SUPER_ID")
    if [ -n "$ACTIVE_SUPER_ID" ]; then
        SP_MODEL=$(super_prop_value ro.product.model)
        SP_CPU=$(extras_value CPU_PROFILE "$SUPER_CONFIG_DIR")
        SP_RAM=$(extras_value RAM_GB "$SUPER_CONFIG_DIR")
        SP_STOR=$(extras_value STORAGE_GB "$SUPER_CONFIG_DIR")
        SP_GPU=$(extras_value GL_RENDERER "$SUPER_CONFIG_DIR")
        [ "$(extras_value US_MODE_ENABLED "$SUPER_CONFIG_DIR")" = "1" ] && SP_US="true"
    fi
    if [ -f "$AUTO_DISABLED_FILE" ]; then
        AUTO_OFF=true
        AUTO_OFF_ID=$(tr -d ' \t\n\r' < "$AUTO_DISABLED_FILE" 2>/dev/null)
        persona_valid_id "$AUTO_OFF_ID" && persona_exists "$AUTO_OFF_ID" && \
            AUTO_OFF_NAME=$(persona_get_name "$AUTO_OFF_ID")
    fi

    STATUS_JSON='{'
    json_set "$VERSION"
    STATUS_JSON="${STATUS_JSON}\"version\":${JSTR},"
    STATUS_JSON="${STATUS_JSON}\"persona_active\":${PERSONA},"
    if [ -n "$ACTIVE_ID" ]; then json_set "$ACTIVE_ID"; JV=$JSTR; else JV=null; fi
    STATUS_JSON="${STATUS_JSON}\"active_persona\":${JV},"
    if [ -n "$ACTIVE_NAME" ]; then json_set "$ACTIVE_NAME"; JV=$JSTR; else JV=null; fi
    STATUS_JSON="${STATUS_JSON}\"active_persona_name\":${JV},"
    STATUS_JSON="${STATUS_JSON}\"super_active\":${SUPER_ACT},"
    if [ -n "$ACTIVE_SUPER_ID" ]; then json_set "$ACTIVE_SUPER_ID"; JV=$JSTR; else JV=null; fi
    STATUS_JSON="${STATUS_JSON}\"active_super_persona\":${JV},"
    if [ -n "$ACTIVE_SUPER_NAME" ]; then json_set "$ACTIVE_SUPER_NAME"; JV=$JSTR; else JV=null; fi
    STATUS_JSON="${STATUS_JSON}\"active_super_persona_name\":${JV},"
    json_set "$SCOPE_MODE"
    STATUS_JSON="${STATUS_JSON}\"scope_mode\":${JSTR},"
    STATUS_JSON="${STATUS_JSON}\"scope_targets\":${SCOPE_CNT:-0},"
    STATUS_JSON="${STATUS_JSON}\"super_scope_targets\":${SUPER_CNT:-0},"
    STATUS_JSON="${STATUS_JSON}\"super_spoof\":${SUPER_ON},"
    STATUS_JSON="${STATUS_JSON}\"super_summary\":{\"model\":$(json_str "$SP_MODEL"),\"cpu_profile\":$(json_str "$SP_CPU"),\"ram_gb\":$(json_str "$SP_RAM"),\"storage_gb\":$(json_str "$SP_STOR"),\"gpu\":$(json_str "$SP_GPU"),\"us_mode\":${SP_US}},"
    STATUS_JSON="${STATUS_JSON}\"zygisk_ready\":${ZYGISK_OK},"
    STATUS_JSON="${STATUS_JSON}\"unsafe_props\":${UNSAFE},"
    STATUS_JSON="${STATUS_JSON}\"reboot_required\":${REBOOT},"
    STATUS_JSON="${STATUS_JSON}\"has_backup\":${BACKUP},"
    STATUS_JSON="${STATUS_JSON}\"auto_disabled\":${AUTO_OFF},"
    if [ -n "$AUTO_OFF_NAME" ]; then json_set "$AUTO_OFF_NAME"; JV=$JSTR; else JV=null; fi
    STATUS_JSON="${STATUS_JSON}\"auto_disabled_name\":${JV},"
    STATUS_JSON="${STATUS_JSON}\"values\":["

    local O_model= O_brand= O_manuf= O_device= O_pname= O_fp= O_vfp= O_bid= O_patch= O_serial= O_plat= O_hw=
    local C_model= C_brand= C_manuf= C_device= C_pname= C_fp= C_vfp= C_bid= C_patch= C_serial= C_plat= C_hw=
    local L_model= L_brand= L_manuf= L_device= L_pname= L_fp= L_vfp= L_bid= L_patch= L_serial= L_plat= L_hw=
    local _K= _V= _ST= _P= _F= _L=

    if [ -f "$BACKUP_FILE" ]; then
        while IFS='=' read -r _K _V || [ -n "$_K" ]; do
            case $_K in
                ro.product.model)                O_model=$_V ;;
                ro.product.brand)                O_brand=$_V ;;
                ro.product.manufacturer)         O_manuf=$_V ;;
                ro.product.device)               O_device=$_V ;;
                ro.product.name)                 O_pname=$_V ;;
                ro.build.fingerprint)            O_fp=$_V ;;
                ro.vendor.build.fingerprint)     O_vfp=$_V ;;
                ro.build.id)                     O_bid=$_V ;;
                ro.build.version.security_patch) O_patch=$_V ;;
                ro.serialno)                     O_serial=$_V ;;
                ro.board.platform)               O_plat=$_V ;;
                ro.hardware)                     O_hw=$_V ;;
            esac
        done < "$BACKUP_FILE"
    fi

    for _F in device_identity build_info identifiers custom; do
        [ -f "${CONFIG_DIR}/${_F}.conf" ] || continue
        grep -q '^FILE_DISABLED' "${CONFIG_DIR}/${_F}.conf" 2>/dev/null && continue
        while IFS=, read -r _ST _P _V || [ -n "$_ST" ]; do
            [ "$_ST" = ENABLED ] || continue
            case $_P in
                ro.product.model)                [ -n "$C_model" ]  || C_model=$_V ;;
                ro.product.brand)                [ -n "$C_brand" ]  || C_brand=$_V ;;
                ro.product.manufacturer)         [ -n "$C_manuf" ]  || C_manuf=$_V ;;
                ro.product.device)               [ -n "$C_device" ] || C_device=$_V ;;
                ro.product.name)                 [ -n "$C_pname" ]  || C_pname=$_V ;;
                ro.build.fingerprint)            [ -n "$C_fp" ]     || C_fp=$_V ;;
                ro.vendor.build.fingerprint)     [ -n "$C_vfp" ]    || C_vfp=$_V ;;
                ro.build.id)                     [ -n "$C_bid" ]    || C_bid=$_V ;;
                ro.build.version.security_patch) [ -n "$C_patch" ]  || C_patch=$_V ;;
                ro.serialno)                     [ -n "$C_serial" ] || C_serial=$_V ;;
                ro.board.platform)               [ -n "$C_plat" ]   || C_plat=$_V ;;
                ro.hardware)                     [ -n "$C_hw" ]     || C_hw=$_V ;;
            esac
        done < "${CONFIG_DIR}/${_F}.conf"
    done

    if [ "$SCOPE_MODE" = "per_app" ] && [ "$(extras_value BUILD_EXTRA_ENABLED)" = "1" ]; then
        [ -n "$C_device" ] || C_device=$(extras_value SPOOF_DEVICE)
        [ -n "$C_pname" ]  || C_pname=$(extras_value SPOOF_NAME)
        [ -n "$C_plat" ]   || C_plat=$(extras_value SPOOF_PLATFORM)
        [ -n "$C_hw" ]     || C_hw=$(extras_value SPOOF_HARDWARE)
        [ -n "$C_patch" ]  || C_patch=$(extras_value SPOOF_SECURITY_PATCH)
    fi

    while IFS= read -r _L; do
        case $_L in
            "[ro.product.model]: ["*"]")                L_model=${_L#*": ["};  L_model=${L_model%"]"} ;;
            "[ro.product.brand]: ["*"]")                L_brand=${_L#*": ["};  L_brand=${L_brand%"]"} ;;
            "[ro.product.manufacturer]: ["*"]")         L_manuf=${_L#*": ["};  L_manuf=${L_manuf%"]"} ;;
            "[ro.product.device]: ["*"]")               L_device=${_L#*": ["}; L_device=${L_device%"]"} ;;
            "[ro.product.name]: ["*"]")                 L_pname=${_L#*": ["};  L_pname=${L_pname%"]"} ;;
            "[ro.build.fingerprint]: ["*"]")            L_fp=${_L#*": ["};     L_fp=${L_fp%"]"} ;;
            "[ro.vendor.build.fingerprint]: ["*"]")     L_vfp=${_L#*": ["};    L_vfp=${L_vfp%"]"} ;;
            "[ro.build.id]: ["*"]")                     L_bid=${_L#*": ["};    L_bid=${L_bid%"]"} ;;
            "[ro.build.version.security_patch]: ["*"]") L_patch=${_L#*": ["};  L_patch=${L_patch%"]"} ;;
            "[ro.serialno]: ["*"]")                     L_serial=${_L#*": ["}; L_serial=${L_serial%"]"} ;;
            "[ro.board.platform]: ["*"]")               L_plat=${_L#*": ["};   L_plat=${L_plat%"]"} ;;
            "[ro.hardware]: ["*"]")                     L_hw=${_L#*": ["};     L_hw=${L_hw%"]"} ;;
        esac
    done <<EOF
$(getprop 2>/dev/null)
EOF

    local SP_STD=1 SP_EXTRA=0
    if [ "$SCOPE_MODE" = "per_app" ]; then
        SP_STD=2
        [ "$(extras_value BUILD_EXTRA_ENABLED)" = "1" ] && SP_EXTRA=2
    fi

    local VAL_FIRST=1
    emit_status_val ro.product.model                "型号 (Model)"          "$SP_STD"   "$L_model"  "$O_model"  "$C_model"
    emit_status_val ro.product.brand                "品牌 (Brand)"          "$SP_STD"   "$L_brand"  "$O_brand"  "$C_brand"
    emit_status_val ro.product.manufacturer         "制造商 (Manufacturer)" "$SP_STD"   "$L_manuf"  "$O_manuf"  "$C_manuf"
    emit_status_val ro.product.device               "设备代号 (Device)"     "$SP_EXTRA" "$L_device" "$O_device" "$C_device"
    emit_status_val ro.product.name                 "产品名 (Product)"      "$SP_EXTRA" "$L_pname"  "$O_pname"  "$C_pname"
    emit_status_val ro.build.fingerprint            "构建指纹 (Fingerprint)" "$SP_STD"  "$L_fp"     "$O_fp"     "$C_fp"
    emit_status_val ro.vendor.build.fingerprint     "Vendor 指纹"           "$SP_STD"   "$L_vfp"    "$O_vfp"    "$C_vfp"
    emit_status_val ro.build.id                     "构建 ID (Build ID)"    "$SP_STD"   "$L_bid"    "$O_bid"    "$C_bid"
    emit_status_val ro.build.version.security_patch "安全补丁日期"          "$SP_EXTRA" "$L_patch"  "$O_patch"  "$C_patch"
    emit_status_val ro.serialno                     "序列号 (Serial)"       "$SP_STD"   "$L_serial" "$O_serial" "$C_serial"
    emit_status_val ro.board.platform               "SoC 平台 (Platform)"   "$SP_EXTRA" "$L_plat"   "$O_plat"   "$C_plat"
    emit_status_val ro.hardware                     "硬件平台 (Hardware)"   "$SP_EXTRA" "$L_hw"     "$O_hw"     "$C_hw"

    printf '%s\n' "${STATUS_JSON}]}"
}

cmd_devices() {
    local JA
    [ -n "$DEVICE_HOST_RELEASE" ] || DEVICE_HOST_RELEASE=$(getprop ro.build.version.release 2>/dev/null)
    json_set "$DEVICE_HOST_RELEASE"; JA=$JSTR
    devices_json
    printf '{"ok":true,"android":%s,"devices":%s}\n' "$JA" "$DEVICES_JSON"
}

is_base64_arg() {
    local T="$1"
    case "$T" in '' | *[!A-Za-z0-9+/=]*) return 1 ;; esac
    [ $(( ${#T} % 4 )) -eq 0 ] || return 1
    T=${T%=}
    T=${T%=}
    case "$T" in '' | *=*) return 1 ;; esac
    return 0
}

is_utf8_hex() {
    local B NEED=0 NEXT=""
    for B in $1; do
        if [ "$NEED" -gt 0 ]; then
            case "${NEXT}:${B}" in
                any:[89ab]?|a0:[ab]?|9f:[89]?|90:[9ab]?|8f:8?) ;;
                *) return 1 ;;
            esac
            NEED=$((NEED - 1))
            NEXT=any
            continue
        fi
        case "$B" in
            [0-7]?) ;;
            c[2-9a-f]|d?) NEED=1; NEXT=any ;;
            e0) NEED=2; NEXT=a0 ;;
            ed) NEED=2; NEXT=9f ;;
            e?) NEED=2; NEXT=any ;;
            f0) NEED=3; NEXT=90 ;;
            f[1-3]) NEED=3; NEXT=any ;;
            f4) NEED=3; NEXT=8f ;;
            *) return 1 ;;
        esac
    done
    [ "$NEED" -eq 0 ]
}

name_from_arg() {
    local ARG="$1" B64 HEX
    case "$ARG" in
        b64:*)
            B64=${ARG#b64:}
            [ -n "$B64" ] || return 0
            if is_base64_arg "$B64"; then
                HEX=$(printf '%s' "$B64" | base64 -d 2>/dev/null | od -An -v -tx1 2>/dev/null)
                if [ -n "$HEX" ] && is_utf8_hex "$HEX"; then
                    printf '%s' "$B64" | base64 -d 2>/dev/null | persona_clean_name
                    return 0
                fi
            fi
            ;;
    esac
    printf '%s' "$ARG" | persona_clean_name
}

cmd_generate() {
    local ARG="$1" KEY="$2" PMODE="${3:-standard}" DEV NAME ID MSG MODE REBOOT_NEEDED=false
    [ "$PMODE" = "super" ] || PMODE="standard"
    if [ -n "$ARG" ] && [ -z "$KEY" ]; then
        if device_resolve_key "$ARG" >/dev/null 2>&1; then
            KEY="$ARG"
            ARG=""
        else
            case "$ARG" in
                *[!a-z0-9_]*) ;;
                *_*)
                    emit_error "未知机型模板：${ARG}，请先查看可用模板列表。"
                    return 1
                    ;;
            esac
        fi
    fi
    DEV=$(device_resolve_key "$KEY") && device_load "$DEV" \
        || { emit_error "未知机型模板：${KEY:-default}。"; return 1; }
    NAME=$(name_from_arg "$ARG")
    [ -n "$NAME" ] || NAME="$DEV_LABEL"
    ID=$(persona_create "$NAME" "$DEV" "$PMODE") || { emit_error "${PERSONA_ERROR:-创建身份失败}"; return 1; }
    persona_activate "$ID" || { emit_error "${PERSONA_ERROR:-激活身份失败}"; return 1; }
    NAME=$(persona_get_name "$ID")
    if [ "$PMODE" = "super" ]; then
        MSG="已生成并启用超级伪装机型“${NAME}”（已自动开启全套新机特征，仅对超级伪装目标列表生效）。"
    else
        MODE=$(get_scope_mode)
        if [ "$MODE" = "per_app" ]; then
            MSG="已生成并启用标准身份“${NAME}”（按应用生效，重开目标应用即可生效）。"
        else
            REBOOT_NEEDED=true
            MSG="已生成并启用标准身份“${NAME}”（全局模式，重启后生效）。"
        fi
    fi
    [ "$DEV_MATCH" = true ] || \
        MSG="${MSG} 注：该机型无 Android ${DEVICE_HOST_RELEASE:-?} 原生构建，已选用 Android ${DEV_RELEASE} 指纹。"
    printf '{"ok":true,"reboot_required":%s,"mode":%s,"id":%s,"name":%s,"message":%s}\n' \
        "$REBOOT_NEEDED" "$(json_str "$PMODE")" "$(json_str "$ID")" "$(json_str "$NAME")" "$(json_str "$MSG")"
}

cmd_activate() {
    local ID="$1" MODE PMODE
    if [ -n "$ID" ]; then
        ID=$(printf '%s' "$ID" | tr -d ' \t\n\r')
    else
        ID=$(persona_active_id 2>/dev/null)
        [ -n "$ID" ] || ID=$(persona_list_ids | tail -n1)
    fi
    [ -n "$ID" ] || { emit_error "暂无可激活的身份，请先生成一个。"; return 1; }
    persona_activate "$ID" || { emit_error "${PERSONA_ERROR:-激活失败}"; return 1; }
    PMODE=$(persona_get_mode "$ID")
    if [ "$PMODE" = "super" ]; then
        printf '{"ok":true,"reboot_required":false,"message":%s}\n' \
            "$(json_str "已切换超级伪装机型（仅对超级伪装目标应用生效，标准模式未受影响）。")"
        return 0
    fi
    MODE=$(get_scope_mode)
    if [ "$MODE" = "per_app" ]; then
        printf '{"ok":true,"reboot_required":false,"message":%s}\n' \
            "$(json_str "已切换标准身份（按应用模式，重开目标应用即可生效）。")"
    else
        emit_ok_reboot "身份已启用，请重启设备生效。"
    fi
}

cmd_deactivate() {
    local DMODE="${1:-all}"
    case "$DMODE" in
        super)
            if persona_super_active_id >/dev/null 2>&1 || [ -f "$SUPER_FLAG" ]; then
                persona_deactivate super
                printf '{"ok":true,"reboot_required":false,"message":%s}\n' \
                    "$(json_str "已关闭超级伪装模式（标准模式与原机不受影响）。")"
            else
                emit_ok "当前未开启超级伪装机型。"
            fi
            ;;
        standard)
            if persona_active_id >/dev/null 2>&1 || [ -f "$PERSONA_FLAG" ]; then
                persona_deactivate standard
                if [ "$(get_scope_mode)" = "per_app" ]; then
                    printf '{"ok":true,"reboot_required":false,"message":%s}\n' \
                        "$(json_str "已关闭默认标准模式（按应用模式下强杀重开目标应用即可生效）。")"
                else
                    emit_ok_reboot "已停用默认标准模式（若之前改过全局属性或 Android ID，重启后恢复原机）。"
                fi
            else
                emit_ok "当前未开启标准模式身份。"
            fi
            ;;
        *)
            if persona_active_id >/dev/null 2>&1 || [ -f "$PERSONA_FLAG" ] || [ -f "$SUPER_FLAG" ]; then
                persona_deactivate all
                emit_ok_reboot "已停用全部伪装身份（若之前改过全局属性或 Android ID，重启后恢复原机）。"
            else
                emit_ok "当前未开启任何伪装身份。"
            fi
            ;;
    esac
}

emit_persona_row() {
    local ID="$1" DIR LINE JI JN JC JB JM JSMODE PMODE
    local NAME=Persona CREATED='' BRAND='' MODEL='' AITGT=0 AIEN=false ACT=false SCTGT=0
    local CPUP='' RAMGB='' STORGB='' GLR=''
    DIR="${PERSONAS_DIR}/${ID}"

    if [ -f "${DIR}/meta" ]; then
        while IFS= read -r LINE || [ -n "$LINE" ]; do
            case $LINE in
                NAME=?*)   NAME=${LINE#NAME=} ;;
                CREATED=*) CREATED=${LINE#CREATED=} ;;
            esac
        done < "${DIR}/meta"
    fi

    if [ -f "${DIR}/device_identity.conf" ]; then
        while IFS= read -r LINE || [ -n "$LINE" ]; do
            case $LINE in
                ENABLED,ro.product.brand,*) [ -n "$BRAND" ] || BRAND=${LINE#ENABLED,ro.product.brand,} ;;
                ENABLED,ro.product.model,*) [ -n "$MODEL" ] || MODEL=${LINE#ENABLED,ro.product.model,} ;;
            esac
        done < "${DIR}/device_identity.conf"
    fi

    if [ -f "${DIR}/android_id.conf" ]; then
        while IFS= read -r LINE || [ -n "$LINE" ]; do
            case $LINE in
                ENABLED) AIEN=true ;;
                PKG=*)   AITGT=$((AITGT + 1)) ;;
            esac
        done < "${DIR}/android_id.conf"
    fi

    if [ -f "${DIR}/extras.conf" ]; then
        while IFS= read -r LINE || [ -n "$LINE" ]; do
            case $LINE in
                CPU_PROFILE=*) CPUP=${LINE#CPU_PROFILE=} ;;
                RAM_GB=*)      RAMGB=${LINE#RAM_GB=} ;;
                STORAGE_GB=*)  STORGB=${LINE#STORAGE_GB=} ;;
                GL_RENDERER=*) GLR=${LINE#GL_RENDERER=} ;;
            esac
        done < "${DIR}/extras.conf"
    fi

    PMODE=$(persona_get_mode "$ID")
    JSMODE=$(persona_scope_mode "$ID")
    if [ "$PMODE" = "super" ]; then
        SCTGT=${SUPER_SCOPE_CNT:-0}
        JSMODE="per_app"
        [ "$ID" = "$PERSONA_SUPER_ACTIVE_ID" ] && ACT=true
    else
        SCTGT=${STD_SCOPE_CNT:-0}
        [ "$ID" = "$PERSONA_ACTIVE_ID" ] && ACT=true
    fi

    json_set "$ID";      JI=$JSTR
    json_set "$NAME";    JN=$JSTR
    json_set "$CREATED"; JC=$JSTR
    json_set "$BRAND";   JB=$JSTR
    json_set "$MODEL";   JM=$JSTR

    [ "$PERSONA_FIRST" -eq 1 ] || PERSONAS_JSON="${PERSONAS_JSON},"
    PERSONA_FIRST=0
    PERSONAS_JSON="${PERSONAS_JSON}{\"id\":${JI},\"name\":${JN},\"created\":${JC},\"mode\":$(json_str "$PMODE"),\"active\":${ACT},\"brand\":${JB},\"model\":${JM},\"cpu_profile\":$(json_str "$CPUP"),\"ram_gb\":$(json_str "$RAMGB"),\"storage_gb\":$(json_str "$STORGB"),\"gl_renderer\":$(json_str "$GLR"),\"android_id_enabled\":${AIEN},\"android_id_targets\":${AITGT},\"scope_mode\":$(json_str "$JSMODE"),\"scope_targets\":${SCTGT}}"
}

cmd_personas_list() {
    local ID PERSONA_FIRST=1 PERSONA_ACTIVE_ID PERSONA_SUPER_ACTIVE_ID JA JAS PERSONAS_JSON="" STD_SCOPE_CNT SUPER_SCOPE_CNT
    PERSONA_ACTIVE_ID=$(persona_active_id 2>/dev/null)
    PERSONA_SUPER_ACTIVE_ID=$(persona_super_active_id 2>/dev/null)
    STD_SCOPE_CNT=$(scope_target_count)
    SUPER_SCOPE_CNT=$(super_scope_target_count)
    if [ -n "$PERSONA_ACTIVE_ID" ]; then json_set "$PERSONA_ACTIVE_ID"; JA=$JSTR; else JA=null; fi
    if [ -n "$PERSONA_SUPER_ACTIVE_ID" ]; then json_set "$PERSONA_SUPER_ACTIVE_ID"; JAS=$JSTR; else JAS=null; fi
    for ID in $(persona_list_ids); do
        emit_persona_row "$ID"
    done
    printf '{"ok":true,"active":%s,"active_super":%s,"std_targets":%s,"super_targets":%s,"personas":[%s]}\n' \
        "$JA" "$JAS" "${STD_SCOPE_CNT:-0}" "${SUPER_SCOPE_CNT:-0}" "$PERSONAS_JSON"
}

cmd_persona_activate() {
    local ID="$1" MODE PMODE
    [ -n "$ID" ] || { emit_error "未提供身份 ID"; return 1; }
    ID=$(printf '%s' "$ID" | tr -d ' \t\n\r')
    persona_activate "$ID" || { emit_error "${PERSONA_ERROR:-激活失败}"; return 1; }
    PMODE=$(persona_get_mode "$ID")
    if [ "$PMODE" = "super" ]; then
        printf '{"ok":true,"reboot_required":false,"message":%s}\n' \
            "$(json_str "已启用超级伪装机型（仅对超级伪装目标应用生效，标准模式列表不变）。")"
        return 0
    fi
    MODE=$(get_scope_mode)
    if [ "$MODE" = "per_app" ]; then
        printf '{"ok":true,"reboot_required":false,"message":%s}\n' \
            "$(json_str "已切换标准身份（按应用模式，重开目标应用即可生效）。")"
    else
        emit_ok_reboot "身份已启用，请重启设备生效。"
    fi
}

cmd_persona_rename() {
    local ID="$1" NAME
    [ -n "$ID" ] || { emit_error "未提供身份 ID"; return 1; }
    NAME=$(name_from_arg "$2")
    [ -n "$NAME" ] || { emit_error "名称不能为空"; return 1; }
    ID=$(printf '%s' "$ID" | tr -d ' \t\n\r')
    persona_rename "$ID" "$NAME" || { emit_error "${PERSONA_ERROR:-重命名失败}"; return 1; }
    emit_ok "已重命名为“$(persona_get_name "$ID")”。"
}

cmd_persona_delete() {
    local ID="$1" PMODE WAS_ACTIVE=0
    [ -n "$ID" ] || { emit_error "未提供身份 ID"; return 1; }
    ID=$(printf '%s' "$ID" | tr -d ' \t\n\r')
    PMODE=$(persona_get_mode "$ID")
    if [ "$PMODE" = "super" ]; then
        [ "$(persona_super_active_id 2>/dev/null)" = "$ID" ] && WAS_ACTIVE=1
    else
        [ "$(persona_active_id 2>/dev/null)" = "$ID" ] && WAS_ACTIVE=1
    fi
    persona_delete "$ID" || { emit_error "${PERSONA_ERROR:-删除失败}"; return 1; }
    if [ "$WAS_ACTIVE" -eq 1 ]; then
        if [ "$PMODE" = "super" ]; then
            printf '{"ok":true,"reboot_required":false,"message":%s}\n' \
                "$(json_str "已删除当前超级伪装身份，重开目标应用即恢复。")"
        elif [ "$(get_scope_mode)" = "per_app" ]; then
            printf '{"ok":true,"reboot_required":false,"message":%s}\n' \
                "$(json_str "已删除当前激活身份（按应用模式下重开应用即恢复）。")"
        else
            emit_ok_reboot "已删除当前激活身份，请重启恢复原机。"
        fi
    else
        emit_ok "已删除身份。"
    fi
}

media_scan() {
    command -v content >/dev/null 2>&1 || return 0
    if command -v timeout >/dev/null 2>&1; then
        timeout 10 content call --uri content://media --method scan_file --arg "$1" >/dev/null 2>&1
    else
        content call --uri content://media --method scan_file --arg "$1" >/dev/null 2>&1
    fi
}

media_scan_later() {
    local F
    command -v content >/dev/null 2>&1 || return 0
    (
        exec </dev/null >/dev/null 2>&1
        trap '' HUP
        for F in "$@"; do
            media_scan "$F"
        done
    ) &
}

cmd_persona_export() {
    local WHICH="${1:-all}" IDS ID COUNT=0 SHOWN FAILED=0
    case "$WHICH" in
        all) IDS=$(persona_list_ids) ;;
        *)   IDS=$(printf '%s' "$WHICH" | tr -d ' \t\n\r') ;;
    esac
    [ -n "$IDS" ] || { emit_error "没有可导出的身份配置。"; return 1; }

    mkdir -p "$PERSONA_EXPORT_DIR" 2>/dev/null
    [ -d "$PERSONA_EXPORT_DIR" ] || { emit_error "无法创建目录 ${PERSONA_EXPORT_DIR}，请先解锁手机屏幕。"; return 1; }

    set --
    for ID in $IDS; do
        persona_export "$ID" "$PERSONA_EXPORT_DIR" || { FAILED=1; break; }
        set -- "$@" "$PERSONA_EXPORTED"
        COUNT=$((COUNT + 1))
    done
    [ "$#" -eq 0 ] || media_scan_later "$@"
    [ "$FAILED" -eq 0 ] || { emit_error "${PERSONA_ERROR:-导出失败}"; return 1; }

    SHOWN=${PERSONA_EXPORT_DIR#/storage/emulated/0/}
    if [ "$COUNT" -eq 1 ]; then
        printf '{"ok":true,"count":1,"path":%s,"message":%s}\n' "$(json_str "$PERSONA_EXPORTED")" \
            "$(json_str "已导出至 ${SHOWN}/${PERSONA_EXPORTED##*/}")"
    else
        printf '{"ok":true,"count":%s,"path":%s,"message":%s}\n' "$COUNT" "$(json_str "$PERSONA_EXPORT_DIR")" \
            "$(json_str "已导出 ${COUNT} 份配置至 ${SHOWN}")"
    fi
}

cmd_persona_imports() {
    local F FIRST=1
    printf '{"ok":true,"dir":%s,"files":[' "$(json_str "$PERSONA_EXPORT_DIR")"
    for F in "$PERSONA_EXPORT_DIR"/*.persona "$PERSONA_EXPORT_DIR"/*.persona.txt \
             "${PERSONA_EXPORT_DIR%/*}"/*.persona "${PERSONA_EXPORT_DIR%/*}"/*.persona.txt; do
        [ -f "$F" ] || continue
        case $F in *[$__JSON_CTRL]*) continue ;; esac
        [ "$FIRST" -eq 1 ] || printf ','
        FIRST=0
        printf '{"path":%s,"file":%s}' "$(json_str "$F")" "$(json_str "${F##*/}")"
    done
    printf ']}'
    printf '\n'
}

cmd_persona_import() {
    local FILE="$1" RC MSG HOST
    [ -n "$FILE" ] || { emit_error "未指定文件"; return 1; }
    persona_import "$FILE"
    RC=$?
    case "$RC" in
        0)
            MSG="已导入“${PERSONA_IMPORTED_NAME}”，在列表打开开关即可启用。"
            HOST=$(getprop ro.build.version.release 2>/dev/null)
            if [ -n "$PERSONA_IMPORTED_RELEASE" ] && [ -n "$HOST" ] && [ "$PERSONA_IMPORTED_RELEASE" != "$HOST" ]; then
                MSG="${MSG} 注意：该模板来自 Android ${PERSONA_IMPORTED_RELEASE}，当前系统为 Android ${HOST}。"
            fi
            printf '{"ok":true,"id":%s,"name":%s,"message":%s}\n' \
                "$(json_str "$PERSONA_IMPORTED_ID")" "$(json_str "$PERSONA_IMPORTED_NAME")" \
                "$(json_str "$MSG")"
            ;;
        2)
            printf '{"ok":true,"skipped":true,"id":%s,"name":%s,"message":%s}\n' \
                "$(json_str "$PERSONA_IMPORTED_ID")" "$(json_str "$PERSONA_IMPORTED_NAME")" \
                "$(json_str "身份“${PERSONA_IMPORTED_NAME}”已存在，已跳过。")"
            ;;
        *)
            emit_error "导入失败：${PERSONA_ERROR:-文件格式无效}"
            return 1
            ;;
    esac
}

cmd_restore() {
    if restore_backup; then
        mark_reboot
        emit_ok_reboot "已还原为原机配置，请重启设备生效。"
    else
        emit_error "未找到原机备份文件。"
    fi
}

cmd_read_config() {
    local NAME="$1" CDIR="$CONFIG_DIR"
    valid_config_name "$NAME" || { echo "ERROR: invalid config name" >&2; return 1; }
    [ "$2" = "super" ] && CDIR="$SUPER_CONFIG_DIR"
    local FILE="${CDIR}/${NAME}"
    [ -f "$FILE" ] || { echo "ERROR: config not found" >&2; return 1; }
    cat "$FILE"
}

cmd_write_config() {
    local NAME="$1" B64="$2" TARGET_MODE="${3:-standard}" MODE CDIR="$CONFIG_DIR"
    valid_config_name "$NAME" || { emit_error "配置文件名无效"; return 1; }
    [ -n "$B64" ] || { emit_error "内容为空"; return 1; }
    B64=$(printf '%s' "$B64" | tr -d ' \t\n\r')
    is_base64_arg "$B64" || { emit_error "非法的 Base64 内容"; return 1; }
    [ "$TARGET_MODE" = "super" ] && CDIR="$SUPER_CONFIG_DIR"

    local FILE="${CDIR}/${NAME}"
    local TMP="${FILE}.tmp.$$"
    if ! printf '%s' "$B64" | base64 -d > "$TMP" 2>/dev/null; then
        rm -f "$TMP"
        emit_error "Base64 解码失败"
        return 1
    fi
    chmod 600 "$TMP" 2>/dev/null
    if ! mv -f "$TMP" "$FILE" 2>/dev/null; then
        rm -f "$TMP"
        emit_error "写入失败"
        return 1
    fi
    local MSG="已保存。"
    if ! freeze_config_generators "$FILE"; then
        log "Config $NAME: a generator token could not be resolved"
        MSG="已保存，但存在无效的随机占位符，请检查格式。"
    fi
    if [ "$TARGET_MODE" = "super" ]; then
        persona_sync_file_from_config "$NAME" super
        log "Super config written: $NAME"
        printf '{"ok":true,"reboot_required":false,"message":%s}\n' \
            "$(json_str "${MSG}（强杀重开超级目标应用即生效）")"
        return 0
    fi
    persona_sync_file_from_config "$NAME" standard
    MODE=$(get_scope_mode)
    log "Config written: $NAME"
    if [ "$MODE" = "per_app" ]; then
        printf '{"ok":true,"reboot_required":false,"message":%s}\n' \
            "$(json_str "${MSG}（按应用模式下强杀重开目标应用即生效）")"
    else
        mark_reboot
        emit_ok_reboot "$MSG"
    fi
}

cmd_scope_config() {
    local MODE PKG FIRST=1 JT="" SFIRST=1 SJT=""
    MODE=$(get_scope_mode)
    while IFS= read -r PKG; do
        [ -n "$PKG" ] || continue
        [ "$FIRST" -eq 1 ] || JT="${JT},"
        FIRST=0
        json_set "$PKG"
        JT="${JT}${JSTR}"
    done <<EOF
$(get_scope_targets)
EOF
    while IFS= read -r PKG; do
        [ -n "$PKG" ] || continue
        [ "$SFIRST" -eq 1 ] || SJT="${SJT},"
        SFIRST=0
        json_set "$PKG"
        SJT="${SJT}${JSTR}"
    done <<EOF
$(get_super_scope_targets)
EOF
    printf '{"ok":true,"mode":%s,"targets":[%s],"super_targets":[%s]}\n' \
        "$(json_str "$MODE")" "$JT" "$SJT"
}

cmd_set_scope() {
    local B64="$1" PAYLOAD LINE OLD_MODE NEW_MODE="per_app" PKGS="" FILE="${CONFIG_DIR}/scope.conf" TMP
    [ -n "$B64" ] || { emit_error "参数为空"; return 1; }
    PAYLOAD=$(printf '%s' "$B64" | base64 -d 2>/dev/null) || { emit_error "Base64 解码失败"; return 1; }
    OLD_MODE=$(get_scope_mode)

    while IFS= read -r LINE || [ -n "$LINE" ]; do
        case "$LINE" in
            MODE=global)  NEW_MODE="global" ;;
            MODE=per_app) NEW_MODE="per_app" ;;
            PKG=*)
                local P="${LINE#PKG=}"
                ai_valid_pkg "$P" && PKGS="${PKGS} ${P}"
                ;;
        esac
    done <<EOF
$PAYLOAD
EOF

    TMP="${FILE}.tmp.$$"
    {
        echo "# DeviceSpoofLabs - 默认标准模式作用模式与目标应用配置"
        echo "MODE=${NEW_MODE}"
        for P in $PKGS; do
            echo "PKG=${P}"
        done
    } > "$TMP" 2>/dev/null || { rm -f "$TMP"; emit_error "无法保存作用域配置"; return 1; }
    chmod 600 "$TMP" 2>/dev/null
    mv -f "$TMP" "$FILE" 2>/dev/null || { rm -f "$TMP"; emit_error "无法写入 scope.conf"; return 1; }
    persona_sync_file_from_config "scope.conf" standard
    log "Standard scope saved: mode=$NEW_MODE targets=$(scope_target_count)"

    if [ "$OLD_MODE" != "$NEW_MODE" ]; then
        mark_reboot
        emit_ok_reboot "标准模式作用范围已切换为“$([ "$NEW_MODE" = "per_app" ] && echo "按应用生效" || echo "全局生效")”，请重启手机使模式切换完全生效。"
    elif [ "$NEW_MODE" = "per_app" ]; then
        printf '{"ok":true,"reboot_required":false,"message":%s}\n' \
            "$(json_str "标准模式目标应用已保存，强杀并重新打开目标应用即可生效。")"
    else
        printf '{"ok":true,"reboot_required":false,"message":%s}\n' \
            "$(json_str "标准模式增强作用域已保存，重开目标应用即可生效。")"
    fi
}

cmd_set_super_scope() {
    local B64="$1" PAYLOAD LINE PKGS="" FILE="${SUPER_CONFIG_DIR}/scope.conf" TMP P
    [ -n "$B64" ] || { emit_error "参数为空"; return 1; }
    PAYLOAD=$(printf '%s' "$B64" | base64 -d 2>/dev/null) || { emit_error "Base64 解码失败"; return 1; }
    mkdir -p "$SUPER_CONFIG_DIR" 2>/dev/null

    while IFS= read -r LINE || [ -n "$LINE" ]; do
        case "$LINE" in
            PKG=*)
                P="${LINE#PKG=}"
                ai_valid_pkg "$P" && PKGS="${PKGS} ${P}"
                ;;
        esac
    done <<EOF
$PAYLOAD
EOF

    TMP="${FILE}.tmp.$$"
    {
        echo "# DeviceSpoofLabs - 超级伪装模式目标应用列表（与标准模式完全独立）"
        echo "MODE=per_app"
        for P in $PKGS; do
            echo "PKG=${P}"
        done
    } > "$TMP" 2>/dev/null || { rm -f "$TMP"; emit_error "无法保存超级伪装目标列表"; return 1; }
    chmod 600 "$TMP" 2>/dev/null
    mv -f "$TMP" "$FILE" 2>/dev/null || { rm -f "$TMP"; emit_error "无法写入 super_config/scope.conf"; return 1; }
    persona_sync_file_from_config "scope.conf" super
    log "Super scope saved: targets=$(super_scope_target_count)"
    printf '{"ok":true,"reboot_required":false,"message":%s}\n' \
        "$(json_str "超级伪装目标应用列表已保存（与默认标准列表独立），强杀并重开对应应用生效。")"
}

cmd_extras_config() {
    local CDIR="$CONFIG_DIR"
    [ "$1" = "super" ] && CDIR="$SUPER_CONFIG_DIR"
    local FILE="${CDIR}/extras.conf" LINE K V FIRST=1
    printf '{"ok":true,"extras":{'
    if [ -f "$FILE" ]; then
        while IFS= read -r LINE || [ -n "$LINE" ]; do
            case "$LINE" in ''|'#'*) continue ;; esac
            case "$LINE" in *=*) ;; *) continue ;; esac
            K=${LINE%%=*}
            V=${LINE#*=}
            [ -n "$K" ] || continue
            [ "$FIRST" -eq 1 ] || printf ','
            FIRST=0
            printf '%s:%s' "$(json_str "$K")" "$(json_str "$V")"
        done < "$FILE"
    fi
    printf '}}\n'
}

cmd_set_extras() {
    local B64="$1" TARGET_MODE="${2:-standard}" CDIR="$CONFIG_DIR"
    [ "$TARGET_MODE" = "super" ] && CDIR="$SUPER_CONFIG_DIR"
    local PAYLOAD FILE="${CDIR}/extras.conf" TMP LINE K V
    [ -n "$B64" ] || { emit_error "参数为空"; return 1; }
    PAYLOAD=$(printf '%s' "$B64" | base64 -d 2>/dev/null) || { emit_error "Base64 解码失败"; return 1; }
    mkdir -p "$CDIR" 2>/dev/null
    TMP="${FILE}.tmp.$$"
    {
        echo "# DeviceSpoofLabs - Zygisk 进程级增强伪装配置 (${TARGET_MODE})"
        printf '%s\n' "$PAYLOAD" | while IFS= read -r LINE || [ -n "$LINE" ]; do
            case "$LINE" in ''|'#'*) continue ;; esac
            case "$LINE" in *=*) ;; *) continue ;; esac
            K=${LINE%%=*}
            V=${LINE#*=}
            case "$K" in
                *[!A-Z0-9_]*) continue ;;
            esac
            [ -n "$K" ] || continue
            printf '%s=%s\n' "$K" "$V"
        done
    } > "$TMP" 2>/dev/null || { rm -f "$TMP"; emit_error "无法写入增强配置"; return 1; }
    chmod 600 "$TMP" 2>/dev/null
    mv -f "$TMP" "$FILE" 2>/dev/null || { rm -f "$TMP"; emit_error "保存失败"; return 1; }
    freeze_config_generators "$FILE" >/dev/null 2>&1 || true
    persona_sync_file_from_config "extras.conf" "$TARGET_MODE"
    log "Extras config saved (mode=${TARGET_MODE})"
    printf '{"ok":true,"reboot_required":false,"message":%s}\n' \
        "$(json_str "配置已保存，强杀并重新打开对应目标应用即可生效。")"
}

cmd_force_stop_targets() {
    local TARGET_MODE="${1:-all}" PKG CNT=0 LIST="" SEEN=" "
    if ! command -v am >/dev/null 2>&1; then
        emit_error "当前环境不支持 am 命令"
        return 1
    fi
    case "$TARGET_MODE" in
        standard) LIST=$(get_scope_targets) ;;
        super)    LIST=$(get_super_scope_targets) ;;
        *)        LIST="$(get_scope_targets)
$(get_super_scope_targets)" ;;
    esac
    for PKG in $LIST; do
        case "$SEEN" in *" $PKG "*) continue ;; esac
        SEEN="${SEEN}${PKG} "
        am force-stop "$PKG" >/dev/null 2>&1 && CNT=$((CNT + 1))
    done
    if [ "$CNT" -eq 0 ]; then
        emit_ok "尚未选择目标应用，无需强杀。"
    else
        log "Force-stopped $CNT target app(s) (mode=${TARGET_MODE})"
        emit_ok "已强行停止 ${CNT} 个目标应用，重新打开即可应用最新配置。"
    fi
}

cmd_sync_ai_targets() {
    local EN=0 VAL USR PKGS
    ai_is_enabled && EN=1
    VAL=$(ai_get_value)
    ai_valid_value "$VAL" || VAL=$(generate_hex 16)
    USR=$(ai_get_user)
    PKGS=$(get_scope_targets)
    if ai_write_config "$EN" "$VAL" "$USR" $PKGS; then
        persona_sync_file_from_config "android_id.conf"
        mark_reboot
        emit_ok_reboot "已将设备伪装目标应用同步至 Android ID 作用域（重启生效）。"
    else
        emit_error "${AI_ERROR:-同步失败}"
        return 1
    fi
}

cmd_gen_identifiers() {
    printf '{"ok":true,"serial":%s,"imei":%s,"mac":%s,"drm_id":%s,"uuid":%s}\n' \
        "$(json_str "$(generate_serial)")" \
        "$(json_str "$(generate_imei)")" \
        "$(json_str "$(generate_mac)")" \
        "$(json_str "$(generate_hex 64)")" \
        "$(json_str "$(generate_uuid)")"
}

cmd_logs() {
    local N="${1:-200}"
    case "$N" in ''|*[!0-9]*) N=200 ;; esac
    if [ -f "$LOG_FILE" ]; then
        tail -n "$N" "$LOG_FILE"
    else
        echo "(暂无日志)"
    fi
}

cmd_clear_logs() {
    : > "$LOG_FILE" 2>/dev/null
    chmod 600 "$LOG_FILE" 2>/dev/null
    log "Logs cleared"
    emit_ok "日志已清空。"
}

cmd_open_url() {
    local B64="$1" URL
    [ -n "$B64" ] || { emit_error "未提供链接"; return 1; }
    URL=$(printf '%s' "$B64" | base64 -d 2>/dev/null | tr -d '\n\r') || { emit_error "Base64 解码失败"; return 1; }
    case "$URL" in
        http://*|https://*) ;;
        *) emit_error "不支持的链接协议"; return 1 ;;
    esac

    if am start -a android.intent.action.VIEW -d "$URL" >/dev/null 2>&1; then
        emit_ok "已打开。"
        return 0
    fi
    emit_error "无法打开外部链接。"
    return 1
}

cmd_ui_log() {
    local B64="$1" MSG
    [ -n "$B64" ] || return 0
    MSG=$(printf '%s' "$B64" | base64 -d 2>/dev/null) || return 0
    MSG=$(printf '%s' "$MSG" | tr '\n\r\t' '   ' | cut -c1-300)
    [ -n "$MSG" ] || return 0
    log "[webui] $MSG"
}

detect_root_manager() {
    if [ -n "$KSU" ] || [ -d /data/adb/ksu ]; then echo "KernelSU"; return; fi
    if [ -n "$APATCH" ] || [ -d /data/adb/ap ]; then echo "APatch"; return; fi
    if [ -n "$MAGISK_VER_CODE" ] || [ -d /data/adb/magisk ]; then echo "Magisk"; return; fi
    echo "unknown"
}

resolve_resetprop_path() {
    local P CAND
    P="$(command -v resetprop 2>/dev/null)"
    if [ -z "$P" ]; then
        for CAND in /data/adb/ksu/bin/resetprop /data/adb/ap/bin/resetprop /data/adb/magisk/resetprop; do
            [ -x "$CAND" ] && { P="$CAND"; break; }
        done
    fi
    echo "$P"
}

collect_diagnostics() {
    local VCODE RP CONF FILE EN HDR KEY LIVE CONFV ORIG ST GUARD
    get_version
    VCODE=$(grep '^versionCode=' "${MODDIR}/module.prop" 2>/dev/null | head -n1 | cut -d= -f2)
    RP=$(resolve_resetprop_path)

    echo "===== DeviceSpoofLabs 诊断信息 ====="
    echo "# generated : $(date '+%Y-%m-%d %H:%M:%S')"
    echo "# 注意：以下包含设备真实与伪装参数，请注意隐私保护。"
    echo
    echo "module.version   : ${VERSION} (versionCode ${VCODE:-?})"
    echo "root.manager     : $(detect_root_manager)"
    echo "selinux          : $(getenforce 2>/dev/null || echo '?')"
    echo "android.release  : $(getprop ro.build.version.release 2>/dev/null) (sdk $(getprop ro.build.version.sdk 2>/dev/null))"
    echo "kernel           : $(uname -r 2>/dev/null)"
    echo "scope.mode       : $(get_scope_mode) (targets: $(scope_target_count))"
    echo "super.scope      : per_app (targets: $(super_scope_target_count))"
    echo "zygisk.so        : $(zygisk_so_present && echo present || echo missing)"
    echo "data.dir         : ${DATA_DIR}"
    echo "module.dir       : ${MODDIR}"
    echo "resetprop        : ${RP:-NOT FOUND}"
    echo "persona_active   : $( [ -f "$PERSONA_FLAG" ] && echo "yes ($PERSONA_FLAG)" || echo no )"
    echo "super_active     : $( [ -f "$SUPER_FLAG" ] && echo "yes ($SUPER_FLAG)" || echo no )"
    echo "backup.conf      : $( [ -f "$BACKUP_FILE" ] && echo yes || echo no )"
    echo "reboot_pending   : $( [ -f "$REBOOT_PENDING" ] && echo yes || echo no )"
    GUARD="not yet"
    [ -f "$BOOT_WATCH_FILE" ] && GUARD=on
    [ -f "$BOOT_GUARD_OFF_FILE" ] && GUARD="switched off"
    echo "boot_attempts    : $(cat "$BOOT_ATTEMPTS_FILE" 2>/dev/null || echo 0) (counting ${GUARD})"
    echo "auto_disabled    : $( [ -f "$AUTO_DISABLED_FILE" ] && echo yes || echo no )"
    echo "unsafe.props     : $( is_unsafe_props_enabled && echo ENABLED || echo off )"
    echo "module.disabled  : $( [ -f "${MODDIR}/disable" ] && echo yes || echo no )"
    echo
    echo "--- config files (in ${CONFIG_DIR}) ---"
    for CONF in device_identity build_info identifiers custom scope extras; do
        FILE="${CONFIG_DIR}/${CONF}.conf"
        if [ -f "$FILE" ]; then
            EN=$(grep -c '^ENABLED,' "$FILE" 2>/dev/null)
            HDR=$(head -n1 "$FILE" 2>/dev/null)
            echo "  ${CONF}.conf: present, ${EN} ENABLED entries, header=[${HDR}]"
        else
            echo "  ${CONF}.conf: MISSING"
        fi
    done
    echo
    echo "--- key identity props: live vs configured vs real ---"
    for KEY in ro.product.model ro.product.brand ro.product.manufacturer \
               ro.build.fingerprint ro.vendor.build.fingerprint ro.serialno \
               ro.bootloader ro.board.platform ro.hardware; do
        LIVE=$(getprop "$KEY" 2>/dev/null)
        CONFV=$(configured_value "$KEY")
        ORIG=$(backup_value "$KEY")
        if [ -n "$CONFV" ] && [ "$LIVE" = "$CONFV" ]; then ST="APPLIED"
        elif [ -n "$CONFV" ]; then ST="CONFIGURED(per-app/pending)"
        else ST="-"; fi
        echo "  ${KEY}: live=[${LIVE}] configured=[${CONFV}] real=[${ORIG}] -> ${ST}"
    done
    echo
    echo "--- permissions / SELinux context ---"
    ls -ldZ "$DATA_DIR" "$CONFIG_DIR" "$PERSONA_FLAG" "${MODDIR}/common/webctl.sh" 2>/dev/null \
        || ls -ld "$DATA_DIR" "$CONFIG_DIR" "$PERSONA_FLAG" "${MODDIR}/common/webctl.sh" 2>/dev/null
}

collect_logcat_snippet() {
    local TMP
    if ! command -v logcat >/dev/null 2>&1; then
        echo "(logcat not available in this context)"
        return
    fi
    TMP="${DATA_DIR}/.logcat.$$"
    if ! logcat -d -b all -v time > "$TMP" 2>/dev/null && ! logcat -d -v time > "$TMP" 2>/dev/null; then
        echo "(logcat read failed)"
        rm -f "$TMP" 2>/dev/null
        return
    fi
    chmod 600 "$TMP" 2>/dev/null
    echo "# Filtered to module / root-manager / resetprop lines + recent SELinux denials."
    echo
    echo "--- module / root-manager / resetprop ---"
    grep -iE 'devicespooflab|DeviceSpoofLabsZ|resetprop|kernelsu|ksud|apatch' "$TMP" | tail -n 250
    echo
    echo "--- recent SELinux denials (avc) ---"
    grep -iE 'avc: *denied' "$TMP" | tail -n 80
    rm -f "$TMP" 2>/dev/null
}

cmd_diagnose() {
    collect_diagnostics
}

cmd_export_logs() {
    local TS DIR DEST=""
    TS=$(date '+%Y%m%d-%H%M%S')
    for DIR in /sdcard/Download /storage/emulated/0/Download /sdcard; do
        if [ -d "$DIR" ] && touch "$DIR/.dsl_w_$$" 2>/dev/null; then
            rm -f "$DIR/.dsl_w_$$" 2>/dev/null
            DEST="$DIR/devicespooflab-log-$TS.txt"
            break
        fi
    done
    [ -n "$DEST" ] || DEST="${DATA_DIR}/devicespooflab-log-$TS.txt"

    {
        collect_diagnostics
        echo
        echo "===== module log (${LOG_FILE}) ====="
        if [ -f "$LOG_FILE" ]; then cat "$LOG_FILE"; else echo "(暂无日志)"; fi
        if [ -f "${LOG_FILE}.1" ]; then
            echo
            echo "===== previous module log (rotated) ====="
            cat "${LOG_FILE}.1"
        fi
        echo
        echo "===== logcat snapshot ====="
        collect_logcat_snippet
    } > "$DEST" 2>/dev/null

    if [ -f "$DEST" ]; then
        log "Logs exported to $DEST (with diagnostics + logcat)"
        printf '{"ok":true,"path":%s}\n' "$(json_str "$DEST")"
    else
        emit_error "导出日志文件失败。"
    fi
}

cmd_reboot() {
    log "Reboot requested via webctl"
    rm -f "$BOOT_ATTEMPTS_FILE" 2>/dev/null
    reboot_runtime
}

cmd_list_apps() {
    local FILTER="${1:-all}" PKG SYS_LIST SRC FIRST=1
    if [ -z "$(command -v pm)" ]; then
        printf '{"ok":false,"apps":[],"message":%s}\n' "$(json_str "pm 命令不可用")"
        return 0
    fi

    SYS_LIST=$(pm list packages -s 2>/dev/null | sed 's/^package://')
    case "$FILTER" in
        user)   SRC=$(pm list packages -3 2>/dev/null | sed 's/^package://') ;;
        system) SRC=$(pm list packages -s 2>/dev/null | sed 's/^package://') ;;
        *)      SRC=$(pm list packages 2>/dev/null | sed 's/^package://') ;;
    esac

    printf '{"ok":true,"apps":['
    printf '%s\n' "$SRC" | sort | while IFS= read -r PKG; do
        [ -n "$PKG" ] || continue
        local SYS=false
        printf '%s\n' "$SYS_LIST" | grep -qxF "$PKG" && SYS=true
        [ "$FIRST" -eq 1 ] || printf ','
        FIRST=0
        printf '{"pkg":%s,"label":%s,"system":%s}' "$(json_str "$PKG")" "$(json_str "$PKG")" "$SYS"
    done
    printf ']}'
    printf '\n'
}

cmd_android_id_config() {
    local ENABLED=false VALUE USER PKG FIRST=1 JV JU JT=""
    ai_is_enabled && ENABLED=true
    VALUE=$(ai_get_value)
    USER=$(ai_get_user)
    json_set "$VALUE"; JV=$JSTR
    json_set "$USER";  JU=$JSTR
    while IFS= read -r PKG; do
        [ -n "$PKG" ] || continue
        [ "$FIRST" -eq 1 ] || JT="${JT},"
        FIRST=0
        json_set "$PKG"
        JT="${JT}${JSTR}"
    done <<EOF
$(ai_get_targets)
EOF
    printf '{"ok":true,"enabled":%s,"value":%s,"user_id":%s,"targets":[%s]}\n' "$ENABLED" "$JV" "$JU" "$JT"
}

cmd_set_android_id() {
    local B64="$1" PAYLOAD LINE EN=0 VAL="" USR=0 PKGS=""
    [ -n "$B64" ] || { emit_error "未提供数据"; return 1; }
    PAYLOAD=$(printf '%s' "$B64" | base64 -d 2>/dev/null) || { emit_error "Base64 解码失败"; return 1; }

    while IFS= read -r LINE || [ -n "$LINE" ]; do
        case "$LINE" in
            ENABLED=1) EN=1 ;;
            ENABLED=0) EN=0 ;;
            VALUE=*)   VAL=${LINE#VALUE=} ;;
            USER=*)    USR=${LINE#USER=} ;;
            PKG=*)     PKGS="${PKGS} ${LINE#PKG=}" ;;
        esac
    done <<EOF
$PAYLOAD
EOF

    ai_valid_value "$VAL" || { emit_error "Android ID 格式错误（需 16 位十六进制字符）"; return 1; }
    ai_valid_user "$USR" || USR=0
    if [ "$EN" = "1" ]; then
        if ! is_persona_active || ! persona_active_id >/dev/null 2>&1; then
            emit_error "请先启用一个设备身份再开启 Android ID 修改。"
            return 1
        fi
    fi

    if ai_write_config "$EN" "$VAL" "$USR" $PKGS; then
        persona_sync_file_from_config "android_id.conf"
        mark_reboot
        log "Android ID config saved (enabled=$EN user=$USR targets=$(ai_target_count))"
        emit_ok_reboot "Android ID 配置已保存（重启手机后生效）。"
    else
        emit_error "${AI_ERROR:-保存 Android ID 配置失败}"
        return 1
    fi
}

cmd_apply_android_id() {
    local CNT SKIP TARGETS MSG
    if ! is_persona_active || ! persona_active_id >/dev/null 2>&1; then
        emit_error "请先启用一个设备身份。"
        return 1
    fi
    TARGETS=$(ai_target_count)
    if [ "${TARGETS:-0}" -le 0 ]; then
        emit_error "未选择目标应用。"
        return 1
    fi
    ai_is_enabled || ai_write_config 1 "$(ai_get_value)" "$(ai_get_user)" $(ai_get_targets) >/dev/null 2>&1
    persona_sync_file_from_config "android_id.conf"

    if ai_apply_config; then
        CNT=${AI_APPLIED_COUNT:-0}
        SKIP="$AI_SKIPPED_PKGS"
        log "Android ID applied: count=$CNT skipped=[$SKIP]"

        if [ "${CNT:-0}" -gt 0 ]; then
            mark_reboot
            MSG="已写入 ${CNT} 个应用的 Android ID，请重启手机生效。"
            [ -n "$SKIP" ] && MSG="${MSG} 尚未生成 SSAID 记录（请先打开一次该应用）：${SKIP}。"
            printf '{"ok":true,"reboot_required":true,"applied":%s,"skipped":%s,"message":%s}\n' \
                "$CNT" "$(json_str "$SKIP")" "$(json_str "$MSG")"
        else
            MSG="暂未写入任何应用：所选应用尚未生成 SSAID 记录，请先打开一次后再试。"
            [ -n "$SKIP" ] && MSG="${MSG} 跳过：${SKIP}。"
            printf '{"ok":true,"reboot_required":false,"applied":0,"skipped":%s,"message":%s}\n' \
                "$(json_str "$SKIP")" "$(json_str "$MSG")"
        fi
    else
        emit_error "${AI_ERROR:-应用 Android ID 失败}"
        return 1
    fi
}

cmd_restore_android_id() {
    local USER
    USER=$(ai_get_user)
    if ai_restore_targets "$USER" $(ai_get_targets); then
        ai_set_enabled 0
        rm -f "$AI_APPLIED_STATE" 2>/dev/null
        persona_sync_file_from_config "android_id.conf"
        mark_reboot
        log "Android ID restored to original for user $USER"
        emit_ok_reboot "已恢复原机 Android ID，重启后生效。"
    else
        emit_error "${AI_ERROR:-恢复原机 Android ID 失败。}"
        return 1
    fi
}

find_busybox() {
    local C P
    P="$(command -v busybox 2>/dev/null)"
    [ -x "$P" ] && { echo "$P"; return; }
    for C in /data/adb/magisk/busybox /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox; do
        [ -x "$C" ] && { echo "$C"; return; }
    done
}

download_url() {
    local URL="$1" DEST="$2" BB
    if command -v curl >/dev/null 2>&1; then
        curl -L --fail --connect-timeout 20 -o "$DEST" "$URL" 2>/dev/null && [ -s "$DEST" ] && return 0
    fi
    if command -v wget >/dev/null 2>&1; then
        wget -O "$DEST" "$URL" 2>/dev/null && [ -s "$DEST" ] && return 0
    fi
    BB="$(find_busybox)"
    [ -n "$BB" ] && "$BB" wget --no-check-certificate -O "$DEST" "$URL" 2>/dev/null && [ -s "$DEST" ] && return 0
    return 1
}

sha256_of() {
    local F="$1" BB
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$F" 2>/dev/null | awk '{print $1}'
        return
    fi
    BB="$(find_busybox)"
    [ -n "$BB" ] && "$BB" sha256sum "$F" 2>/dev/null | awk '{print $1}'
}

size_of() {
    stat -c %s "$1" 2>/dev/null || wc -c < "$1" 2>/dev/null | tr -d ' '
}

ksuwebui_installed() {
    pm path "$KSUWEBUI_PKG" >/dev/null 2>&1
}

am_start() {
    local OUT
    OUT=$(am start "$@" 2>&1) || return 1
    case "$OUT" in *Error*) return 1 ;; esac
    return 0
}

launch_ksuwebui() {
    log "[webui] launch $KSUWEBUI_ACTIVITY id=$MODULE_ID"
    am_start -n "$KSUWEBUI_ACTIVITY" -e id "$MODULE_ID" -e name "$MODULE_NAME"
}

webuix_installed() {
    pm path "$WEBUIX_PKG" >/dev/null 2>&1
}

launch_webuix() {
    local ACT
    for ACT in "$WEBUIX_ACTIVITY" "$WEBUIX_ACTIVITY_OLD"; do
        log "[webui] launch $ACT MODULE_ID=$MODULE_ID"
        am_start -n "$ACT" -e MODULE_ID "$MODULE_ID" -e MOD_ID "$MODULE_ID" -e id "$MODULE_ID" && return 0
    done
    return 1
}

pkg_installed() {
    pm path "$1" >/dev/null 2>&1
}

launch_native_webui_component() {
    local PKG="$1" CLASS="$2" SCHEME="$3"
    log "[webui] launch native $PKG/$CLASS id=$MODULE_ID"
    am_start -a android.intent.action.VIEW \
        -n "${PKG}/${CLASS}" \
        -d "${SCHEME}://webui?id=${MODULE_ID}" \
        -e id "$MODULE_ID" \
        -e name "$MODULE_NAME"
}

launch_native_manager_webui() {
    local MGR="$1" PKG

    case "$MGR" in
        KernelSU)
            for PKG in me.weishu.kernelsu me.weishu.kernelsu.dev; do
                if pkg_installed "$PKG" && launch_native_webui_component "$PKG" "me.weishu.kernelsu.ui.webui.WebUIActivity" ksu; then
                    return 0
                fi
            done
            for PKG in com.rifsxd.ksunext; do
                if pkg_installed "$PKG" && launch_native_webui_component "$PKG" "com.rifsxd.ksunext.ui.webui.WebUIActivity" ksu; then
                    return 0
                fi
            done
            for PKG in com.sukisu.ultra; do
                if pkg_installed "$PKG" && launch_native_webui_component "$PKG" "com.sukisu.ultra.ui.webui.WebUIActivity" ksu; then
                    return 0
                fi
            done
            ;;
        APatch)
            for PKG in me.bmax.apatch me.garfieldhan.apatch.next; do
                if pkg_installed "$PKG" && launch_native_webui_component "$PKG" "me.bmax.apatch.ui.WebUIActivity" apatch; then
                    return 0
                fi
                if pkg_installed "$PKG" && launch_native_webui_component "$PKG" "me.garfieldhan.apatch.next.ui.WebUIActivity" apatch; then
                    return 0
                fi
            done
            ;;
    esac

    return 1
}

open_release_page() {
    echo "  Opening the KsuWebUI download page so you can install it manually:"
    echo "    $KSUWEBUI_RELEASE_PAGE"
    am start -a android.intent.action.VIEW -d "$KSUWEBUI_RELEASE_PAGE" >/dev/null 2>&1
}

install_ksuwebui() {
    local APK="${DSL_WEBUI_APK:-/data/local/tmp/dsl-ksuwebui.apk}" GOT_SHA GOT_SIZE
    rm -f "$APK" 2>/dev/null

    echo "  Downloading KsuWebUI host app (~1.7 MB)..."
    log "[webui] download $KSUWEBUI_APK_URL"
    if ! download_url "$KSUWEBUI_APK_URL" "$APK"; then
        echo "  ! Download failed - no network, or no curl/wget/busybox available."
        log "[webui] download FAILED"
        rm -f "$APK" 2>/dev/null
        return 1
    fi

    GOT_SIZE=$(size_of "$APK")
    GOT_SHA=$(sha256_of "$APK")
    if [ "$GOT_SIZE" != "$KSUWEBUI_APK_SIZE" ] || [ "$GOT_SHA" != "$KSUWEBUI_APK_SHA256" ]; then
        echo "  ! Verification failed - the downloaded file does not match the pinned APK."
        log "[webui] verify FAILED got sha=$GOT_SHA size=$GOT_SIZE"
        rm -f "$APK" 2>/dev/null
        return 1
    fi
    echo "  Verified (SHA-256 + size). Installing..."
    log "[webui] verified OK; pm install"

    chmod 644 "$APK" 2>/dev/null
    if ! pm install -r -S "$GOT_SIZE" < "$APK" >/dev/null 2>&1; then
        pm install -r "$APK" >/dev/null 2>&1
    fi
    rm -f "$APK" 2>/dev/null

    if ksuwebui_installed; then
        echo "  KsuWebUI installed."
        log "[webui] install OK"
        return 0
    fi
    echo "  ! Install did not register the package."
    log "[webui] install FAILED (pm path empty)"
    return 1
}

cmd_open_webui() {
    local MGR
    get_version
    MGR=$(detect_root_manager)
    echo "DeviceSpoofLabs WebUI 启动器 (${VERSION})"

    if [ "$MGR" = "KernelSU" ] || [ "$MGR" = "APatch" ]; then
        echo "  正在通过 $MGR 原生 WebUI 打开..."
        if launch_native_manager_webui "$MGR"; then
            echo "  已打开。"
            return 0
        fi
        echo "  ! 无法启动原生 $MGR WebUI。"
        log "[webui] native $MGR launch FAILED"
        return 1
    fi

    if webuix_installed; then
        if launch_webuix; then
            echo "  已在 WebUI X 中打开。"
            return 0
        fi
        open_release_page
        return 1
    fi

    if ! ksuwebui_installed; then
        if ! install_ksuwebui; then
            open_release_page
            return 1
        fi
    fi

    if launch_ksuwebui; then
        echo "  已打开。"
        return 0
    fi
    open_release_page
    return 1
}

print_help() {
    cat <<EOF
DeviceSpoofLabs control (webctl) - non-interactive

Usage: devicespooflabs <command> [args]

  status                        JSON status
  personas                      List saved personas as JSON
  devices                       List the device catalog and hardware profiles as JSON
  generate-persona [name] [key] [mode] Create & activate (standard|super)
  activate [id]                 Activate a persona
  persona-activate <id>         Activate persona by id
  persona-rename <id> <name>    Rename a persona
  persona-delete <id>           Delete a persona
  persona-export [id|all]       Export personas to /sdcard/Download/DeviceSpoofLabs
  persona-imports               List .persona files
  persona-import <path>         Import a .persona file
  deactivate [standard|super|all] Deactivate persona slot
  restore-backup                Restore original values from backup
  read-config <file> [mode]     Print a config file
  write-config <file> <b64> [m] Replace a config file
  scope-config                  Print standard & super target packages JSON
  set-scope <base64>            Save standard mode & target packages
  set-super-scope <base64>      Save super spoof target packages
  extras-config [mode]          Print Zygisk extra spoofing config JSON
  set-extras <base64> [mode]    Save Zygisk extra spoofing config
  force-stop-targets [mode]     Force-stop scoped target apps (standard|super|all)
  sync-ai-targets               Copy scope target apps to Android ID targets
  gen-identifiers               Generate fresh serial, Luhn IMEI, MAC, DRM ID, UUID
  list-apps [all|user|system]   List installed packages as JSON
  android-id-config             Print Android ID config as JSON
  set-android-id <base64>       Save Android ID config
  apply-android-id              Apply Android ID to SSAID store
  restore-android-id            Restore original Android IDs
  logs [n]                      Print last n log lines
  clear-logs                    Truncate log file
  export-logs                   Export diagnostics + log + logcat
  diagnose                      Print diagnostic snapshot
  open-url <base64url>          Open URL
  ui-log <base64>               Append webui log
  reboot                        Reboot device
  webui                         Open WebUI
EOF
}

case "${1:-status}" in
    status)                     cmd_status ;;
    personas|personas-list)     cmd_personas_list ;;
    devices)                    cmd_devices ;;
    generate-persona|generate)  cmd_generate "$2" "$3" "$4" ;;
    activate)                   cmd_activate "$2" ;;
    persona-activate)           cmd_persona_activate "$2" ;;
    persona-rename)             cmd_persona_rename "$2" "$3" ;;
    persona-delete)             cmd_persona_delete "$2" ;;
    persona-export)             cmd_persona_export "$2" ;;
    persona-imports)            cmd_persona_imports ;;
    persona-import)             cmd_persona_import "$2" ;;
    deactivate)                 cmd_deactivate "$2" ;;
    restore-backup|restore)     cmd_restore ;;
    read-config)                cmd_read_config "$2" "$3" ;;
    write-config)               cmd_write_config "$2" "$3" "$4" ;;
    scope-config)               cmd_scope_config ;;
    set-scope)                  cmd_set_scope "$2" ;;
    set-super-scope)            cmd_set_super_scope "$2" ;;
    extras-config)              cmd_extras_config "$2" ;;
    set-extras)                 cmd_set_extras "$2" "$3" ;;
    force-stop-targets)         cmd_force_stop_targets "$2" ;;
    sync-ai-targets)            cmd_sync_ai_targets ;;
    gen-identifiers)            cmd_gen_identifiers ;;
    list-apps)                  cmd_list_apps "$2" ;;
    android-id-config)          cmd_android_id_config ;;
    set-android-id)             cmd_set_android_id "$2" ;;
    apply-android-id)           cmd_apply_android_id ;;
    restore-android-id)         cmd_restore_android_id ;;
    logs)                       cmd_logs "$2" ;;
    clear-logs)                 cmd_clear_logs ;;
    export-logs)                cmd_export_logs ;;
    diagnose|diagnostics)       cmd_diagnose ;;
    open-url)                   cmd_open_url "$2" ;;
    ui-log)                     cmd_ui_log "$2" ;;
    reboot)                     cmd_reboot ;;
    webui|open-webui)           cmd_open_webui ;;
    version)                    get_version; printf '{"version":%s}\n' "$(json_str "$VERSION")" ;;
    help|-h|--help)             print_help ;;
    *)                          emit_error "未知命令: ${1}"; exit 1 ;;
esac
