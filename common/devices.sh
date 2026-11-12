#!/system/bin/sh
# Device catalog: real builds from config/devices.conf and hardware profiles from config/device_profiles.conf.

MODULE_CONFIG_DIR="${MODULE_CONFIG_DIR:-${MODDIR}/config}"
DEVICES_CONF="${DEVICES_CONF:-${MODULE_CONFIG_DIR}/devices.conf}"
DEVICE_PROFILES_CONF="${DEVICE_PROFILES_CONF:-${MODULE_CONFIG_DIR}/device_profiles.conf}"
DEVICE_HOST_RELEASE=""

device_valid_key() {
    case "$1" in
        '' | *[!a-z0-9_]*) return 1 ;;
    esac
    return 0
}

device_keys() {
    local K R SEEN=" "
    [ -f "$DEVICES_CONF" ] || return 0
    while IFS='|' read -r K R || [ -n "$K" ]; do
        device_valid_key "$K" || continue
        case "$SEEN" in *" ${K} "*) continue ;; esac
        SEEN="${SEEN}${K} "
        echo "$K"
    done < "$DEVICES_CONF"
}

device_row() {
    local KEY="$1" LINE FP REL FIRST="" HOST BEST="" BEST_DIST="" DIST
    DEV_ROW=""
    device_valid_key "$KEY" && [ -f "$DEVICES_CONF" ] || return 1
    HOST=${DEVICE_HOST_RELEASE%%.*}
    case "$HOST" in '' | 0* | *[!0-9]* | ????*) HOST="" ;; esac
    while IFS= read -r LINE || [ -n "$LINE" ]; do
        case "$LINE" in "${KEY}|"*) ;; *) continue ;; esac
        [ -n "$FIRST" ] || FIRST="$LINE"
        FP=${LINE#*"|"}; FP=${FP#*"|"}; FP=${FP%%"|"*}
        REL=${FP#*:}; REL=${REL%%/*}
        if [ -n "$DEVICE_HOST_RELEASE" ] && [ "$REL" = "$DEVICE_HOST_RELEASE" ]; then
            DEV_ROW=$LINE
            return 0
        fi
        [ -n "$HOST" ] || continue
        case "$REL" in '' | 0* | *[!0-9]* | ????*) continue ;; esac
        DIST=$((REL - HOST))
        [ "$DIST" -ge 0 ] || DIST=$((HOST - REL))
        if [ -z "$BEST_DIST" ] || [ "$DIST" -lt "$BEST_DIST" ]; then
            BEST="$LINE"
            BEST_DIST=$DIST
        fi
    done < "$DEVICES_CONF"
    [ -n "$BEST" ] || BEST="$FIRST"
    [ -n "$BEST" ] || return 1
    DEV_ROW=$BEST
}

device_load() {
    local R
    [ -n "$DEVICE_HOST_RELEASE" ] || DEVICE_HOST_RELEASE=$(getprop ro.build.version.release 2>/dev/null)
    device_row "$1" || return 1
    IFS='|' read -r DEV_KEY DEV_LABEL DEV_FP DEV_MANUF DEV_MODEL DEV_INCR DEV_DISPLAY DEV_DESC <<EOF
$DEV_ROW
EOF
    case "$DEV_FP" in */*/*:*/*/*:*/*) ;; *) return 1 ;; esac
    DEV_BRAND=${DEV_FP%%/*}
    R=${DEV_FP#*:}
    DEV_RELEASE=${R%%/*}; R=${R#*/}
    DEV_ID=${R%%/*}; R=${R#*/}; R=${R#*:}
    DEV_TYPE=${R%%/*}
    DEV_TAGS=${R#*/}
    DEV_FLAVOR=${DEV_DESC%% *}
    DEV_MATCH=false
    [ "$DEV_RELEASE" = "$DEVICE_HOST_RELEASE" ] && DEV_MATCH=true
    for R in "$DEV_LABEL" "$DEV_BRAND" "$DEV_MANUF" "$DEV_MODEL" "$DEV_RELEASE" "$DEV_ID" \
             "$DEV_INCR" "$DEV_DISPLAY" "$DEV_DESC" "$DEV_TYPE" "$DEV_TAGS"; do
        [ -n "$R" ] || return 1
    done
    return 0
}

device_profile_load() {
    local KEY="$1" LINE K
    DEV_PROF_DEVICE=""
    DEV_PROF_NAME=""
    DEV_PROF_BOARD=""
    DEV_PROF_PLATFORM=""
    DEV_PROF_HARDWARE=""
    DEV_PROF_SOC_MANUF=""
    DEV_PROF_SOC_MODEL=""
    DEV_PROF_GL_VENDOR=""
    DEV_PROF_GL_RENDERER=""
    DEV_PROF_GL_VERSION=""
    DEV_PROF_UNAME_RELEASE=""
    DEV_PROF_CPU_PROFILE=""
    DEV_PROF_RAM_GB=""
    DEV_PROF_STORAGE_GB=""
    DEV_PROF_BATTERY_MAH=""
    DEV_PROF_VK_VENDOR_ID=""
    DEV_PROF_VK_DEVICE_ID=""
    DEV_PROF_SOC_FAMILY=""
    DEV_PROF_SOC_ID=""
    DEV_PROF_SOC_MACHINE=""
    device_valid_key "$KEY" && [ -f "$DEVICE_PROFILES_CONF" ] || return 1
    while IFS= read -r LINE || [ -n "$LINE" ]; do
        case "$LINE" in "${KEY}|"*) ;; *) continue ;; esac
        IFS='|' read -r K DEV_PROF_DEVICE DEV_PROF_NAME DEV_PROF_BOARD DEV_PROF_PLATFORM \
            DEV_PROF_HARDWARE DEV_PROF_SOC_MANUF DEV_PROF_SOC_MODEL \
            DEV_PROF_GL_VENDOR DEV_PROF_GL_RENDERER DEV_PROF_GL_VERSION DEV_PROF_UNAME_RELEASE \
            DEV_PROF_CPU_PROFILE DEV_PROF_RAM_GB DEV_PROF_STORAGE_GB DEV_PROF_BATTERY_MAH \
            DEV_PROF_VK_VENDOR_ID DEV_PROF_VK_DEVICE_ID DEV_PROF_SOC_FAMILY DEV_PROF_SOC_ID \
            DEV_PROF_SOC_MACHINE <<EOF
$LINE
EOF
        return 0
    done < "$DEVICE_PROFILES_CONF"
    return 1
}

device_resolve_key() {
    local KEY="$1" N I R
    case "$KEY" in
        '')
            KEY=$(device_keys | head -n1)
            ;;
        random)
            N=$(device_keys | grep -c .)
            [ "${N:-0}" -gt 0 ] || return 1
            R=$(LC_ALL=C tr -dc '0-9' < /dev/urandom 2>/dev/null | dd bs=1 count=4 2>/dev/null)
            I=$(( 1${R} % N + 1 ))
            KEY=$(device_keys | sed -n "${I}p")
            ;;
        *)
            device_valid_key "$KEY" && device_keys | grep -qxF "$KEY" || return 1
            ;;
    esac
    [ -n "$KEY" ] || return 1
    printf '%s' "$KEY"
}

device_prop_value() {
    case "$1" in
        ro.product.brand|ro.product.product.brand|ro.product.system.brand|ro.product.system_ext.brand)
            DEV_VALUE=$DEV_BRAND ;;
        ro.product.manufacturer|ro.product.product.manufacturer|\
        ro.product.system.manufacturer|ro.product.system_ext.manufacturer)
            DEV_VALUE=$DEV_MANUF ;;
        ro.product.model|ro.product.product.model|ro.product.system.model|ro.product.system_ext.model)
            DEV_VALUE=$DEV_MODEL ;;
        ro.build.fingerprint|ro.product.build.fingerprint|ro.system.build.fingerprint|\
        ro.system_ext.build.fingerprint|ro.vendor.build.fingerprint|ro.odm.build.fingerprint)
            DEV_VALUE=$DEV_FP ;;
        ro.build.id|ro.product.build.id|ro.vendor.build.id)
            DEV_VALUE=$DEV_ID ;;
        ro.build.display.id)
            DEV_VALUE=$DEV_DISPLAY ;;
        ro.build.version.incremental|ro.product.build.version.incremental|\
        ro.vendor.build.version.incremental|ro.odm.build.version.incremental)
            DEV_VALUE=$DEV_INCR ;;
        ro.build.type|ro.product.build.type|ro.vendor.build.type)
            DEV_VALUE=$DEV_TYPE ;;
        ro.build.tags|ro.product.build.tags|ro.vendor.build.tags)
            DEV_VALUE=$DEV_TAGS ;;
        ro.build.description)
            DEV_VALUE=$DEV_DESC ;;
        ro.build.flavor)
            DEV_VALUE=$DEV_FLAVOR ;;
        *)
            return 1 ;;
    esac
}

device_render() {
    local FILE="$1" TMP="${1}.tmp.$$" LINE ST REST PROP OUT="" NL='
'
    [ -f "$FILE" ] || return 0
    while IFS= read -r LINE || [ -n "$LINE" ]; do
        case "$LINE" in
            ENABLED,*|DISABLED,*)
                ST=${LINE%%,*}
                REST=${LINE#*,}
                PROP=${REST%%,*}
                device_prop_value "$PROP" && LINE="${ST},${PROP},${DEV_VALUE}"
                ;;
        esac
        OUT="${OUT}${LINE}${NL}"
    done < "$FILE"
    printf '%s' "$OUT" > "$TMP" || { rm -f "$TMP"; return 1; }
    chmod 600 "$TMP" 2>/dev/null
    mv -f "$TMP" "$FILE"
}

devices_json() {
    local KEY FIRST=1 JK JL JA JM JDEV JBRD JPLT JHW JSMN JSMD JGV JGR JGVN JUR
    local JCP JRM JST JBT JVV JVD JSF JSI JSM
    DEVICES_JSON='['
    for KEY in $(device_keys); do
        device_load "$KEY" || continue
        json_set "$DEV_KEY";     JK=$JSTR
        json_set "$DEV_LABEL";   JL=$JSTR
        json_set "$DEV_RELEASE"; JA=$JSTR
        json_set "$DEV_MODEL";   JM=$JSTR
        if device_profile_load "$KEY"; then
            json_set "$DEV_PROF_DEVICE"; JDEV=$JSTR
            json_set "$DEV_PROF_BOARD"; JBRD=$JSTR
            json_set "$DEV_PROF_PLATFORM"; JPLT=$JSTR
            json_set "$DEV_PROF_HARDWARE"; JHW=$JSTR
            json_set "$DEV_PROF_SOC_MANUF"; JSMN=$JSTR
            json_set "$DEV_PROF_SOC_MODEL"; JSMD=$JSTR
            json_set "$DEV_PROF_GL_VENDOR"; JGV=$JSTR
            json_set "$DEV_PROF_GL_RENDERER"; JGR=$JSTR
            json_set "$DEV_PROF_GL_VERSION"; JGVN=$JSTR
            json_set "$DEV_PROF_UNAME_RELEASE"; JUR=$JSTR
            json_set "$DEV_PROF_CPU_PROFILE"; JCP=$JSTR
            json_set "$DEV_PROF_RAM_GB"; JRM=$JSTR
            json_set "$DEV_PROF_STORAGE_GB"; JST=$JSTR
            json_set "$DEV_PROF_BATTERY_MAH"; JBT=$JSTR
            json_set "$DEV_PROF_VK_VENDOR_ID"; JVV=$JSTR
            json_set "$DEV_PROF_VK_DEVICE_ID"; JVD=$JSTR
            json_set "$DEV_PROF_SOC_FAMILY"; JSF=$JSTR
            json_set "$DEV_PROF_SOC_ID"; JSI=$JSTR
            json_set "$DEV_PROF_SOC_MACHINE"; JSM=$JSTR
        else
            JDEV='""'; JBRD='""'; JPLT='""'; JHW='""'; JSMN='""'; JSMD='""'
            JGV='""'; JGR='""'; JGVN='""'; JUR='""'
            JCP='""'; JRM='""'; JST='""'; JBT='""'; JVV='""'; JVD='""'
            JSF='""'; JSI='""'; JSM='""'
        fi
        [ "$FIRST" -eq 1 ] || DEVICES_JSON="${DEVICES_JSON},"
        FIRST=0
        DEVICES_JSON="${DEVICES_JSON}{\"key\":${JK},\"label\":${JL},\"android\":${JA},\"model\":${JM},\"match\":${DEV_MATCH},\"profile\":{\"device\":${JDEV},\"board\":${JBRD},\"platform\":${JPLT},\"hardware\":${JHW},\"soc_manuf\":${JSMN},\"soc_model\":${JSMD},\"gl_vendor\":${JGV},\"gl_renderer\":${JGR},\"gl_version\":${JGVN},\"uname_release\":${JUR},\"cpu_profile\":${JCP},\"ram_gb\":${JRM},\"storage_gb\":${JST},\"battery_mah\":${JBT},\"vk_vendor_id\":${JVV},\"vk_device_id\":${JVD},\"soc_family\":${JSF},\"soc_id\":${JSI},\"soc_machine\":${JSM}}}"
    done
    DEVICES_JSON="${DEVICES_JSON}]"
}
