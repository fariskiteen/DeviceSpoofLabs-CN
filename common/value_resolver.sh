#!/system/bin/sh
value_resolver_log() {
    case "$(type log 2>/dev/null)" in
        *function*)
            log "$1"
            ;;
    esac
}

replace_first() {
    local TEXT="$1"
    local NEEDLE="$2"
    local REPLACEMENT="$3"
    local PREFIX SUFFIX

    PREFIX=${TEXT%%"$NEEDLE"*}
    SUFFIX=${TEXT#*"$NEEDLE"}
    printf '%s%s%s\n' "$PREFIX" "$REPLACEMENT" "$SUFFIX"
}

generate_hex() {
    local LENGTH=${1:-16}

    case "$LENGTH" in
        ''|*[!0-9]*) LENGTH=16 ;;
    esac
    [ "$LENGTH" -lt 1 ] && LENGTH=16

    LC_ALL=C tr -dc 'a-f0-9' < /dev/urandom | dd bs=1 count="$LENGTH" 2>/dev/null
}

generate_serial() {
    LC_ALL=C tr -dc 'A-Z0-9' < /dev/urandom | dd bs=1 count=12 2>/dev/null
}

generate_mac() {
    local H B0
    H=$(generate_hex 12)
    B0=$(printf '%s' "$H" | cut -c1-2)
    # Force locally administered unicast (bit 1 = 1, bit 0 = 0 -> second hex nibble 2/6/a/e)
    case "$B0" in
        ?*) B0="$(printf '%s' "$B0" | cut -c1)2" ;;
    esac
    printf '%s:%s:%s:%s:%s:%s' \
        "$B0" \
        "$(printf '%s' "$H" | cut -c3-4)" \
        "$(printf '%s' "$H" | cut -c5-6)" \
        "$(printf '%s' "$H" | cut -c7-8)" \
        "$(printf '%s' "$H" | cut -c9-10)" \
        "$(printf '%s' "$H" | cut -c11-12)"
}

generate_uuid() {
    local H
    H=$(generate_hex 32)
    printf '%s-%s-4%s-a%s-%s' \
        "$(printf '%s' "$H" | cut -c1-8)" \
        "$(printf '%s' "$H" | cut -c9-12)" \
        "$(printf '%s' "$H" | cut -c14-16)" \
        "$(printf '%s' "$H" | cut -c18-20)" \
        "$(printf '%s' "$H" | cut -c21-32)"
}

generate_imei() {
    # Realistic 8-digit TAC + 6 random digits + 1 Luhn check digit = 15 digits
    local TACS="86194205 86743206 35418912 35897211 86391405 35621810"
    local R IDX=1 TAC="" RAND6 BASE14 I=1 SUM=0 D CHECK
    R=$(LC_ALL=C tr -dc '0-9' < /dev/urandom | dd bs=1 count=2 2>/dev/null)
    IDX=$(( 1${R:-00} % 6 + 1 ))
    set -- $TACS
    eval "TAC=\${$IDX}"
    RAND6=$(LC_ALL=C tr -dc '0-9' < /dev/urandom | dd bs=1 count=6 2>/dev/null)
    BASE14="${TAC}${RAND6}"
    while [ "$I" -le 14 ]; do
        D=$(printf '%s' "$BASE14" | cut -c"$I")
        if [ $((I % 2)) -eq 0 ]; then
            D=$((D * 2))
            [ "$D" -gt 9 ] && D=$((D - 9))
        fi
        SUM=$((SUM + D))
        I=$((I + 1))
    done
    CHECK=$(( (10 - (SUM % 10)) % 10 ))
    printf '%s%s' "$BASE14" "$CHECK"
}

resolve_value() {
    local VALUE="$1"
    local TOKEN REPLACEMENT LEN

    while :; do
        case "$VALUE" in
            *'${RANDOM_HEX:'*'}'*)
                TOKEN=$(printf '%s\n' "$VALUE" | sed -n 's/.*\(\${RANDOM_HEX:[0-9][0-9]*}\).*/\1/p')
                [ -z "$TOKEN" ] && break
                LEN=$(printf '%s\n' "$TOKEN" | sed 's/${RANDOM_HEX:\([0-9][0-9]*\)}/\1/')
                REPLACEMENT=$(generate_hex "$LEN")
                VALUE=$(replace_first "$VALUE" "$TOKEN" "$REPLACEMENT")
                ;;
            *'${RANDOM_SERIAL}'*)
                REPLACEMENT=$(generate_serial)
                VALUE=$(replace_first "$VALUE" '${RANDOM_SERIAL}' "$REPLACEMENT")
                ;;
            *'${RANDOM_MAC}'*)
                REPLACEMENT=$(generate_mac)
                VALUE=$(replace_first "$VALUE" '${RANDOM_MAC}' "$REPLACEMENT")
                ;;
            *'${RANDOM_UUID}'*)
                REPLACEMENT=$(generate_uuid)
                VALUE=$(replace_first "$VALUE" '${RANDOM_UUID}' "$REPLACEMENT")
                ;;
            *'${RANDOM_IMEI}'*)
                REPLACEMENT=$(generate_imei)
                VALUE=$(replace_first "$VALUE" '${RANDOM_IMEI}' "$REPLACEMENT")
                ;;
            *)
                break
                ;;
        esac
    done

    case "$VALUE" in
        *'${RANDOM_'*)
            value_resolver_log "Unresolved generator token in config value"
            return 1
            ;;
    esac

    printf '%s\n' "$VALUE"
}

has_generator_token() {
    case "$1" in
        *'${RANDOM_'*) return 0 ;;
        *) return 1 ;;
    esac
}

freeze_config_generators() {
    local FILE="$1"
    local TMP="${FILE}.tmp.$$"
    local LINE STATUS PROP RAW VALUE REST KEY OUT="" CHANGED=0 NL='
'

    FREEZE_CONFIG_CHANGED=0
    [ -f "$FILE" ] || return 0

    while IFS= read -r LINE || [ -n "$LINE" ]; do
        case "$LINE" in
            ''|'#'*|FILE_ENABLED|FILE_DISABLED)
                OUT="${OUT}${LINE}${NL}"
                continue
                ;;
            *'${RANDOM_'*) ;;
            *)
                OUT="${OUT}${LINE}${NL}"
                continue
                ;;
        esac

        case "$LINE" in
            *,*)
                STATUS=${LINE%%,*}
                REST=${LINE#*,}
                PROP=${REST%%,*}
                RAW=${REST#*,}
                if [ "$STATUS" != "$LINE" ] && [ -n "$PROP" ] && has_generator_token "$RAW"; then
                    VALUE=$(resolve_value "$RAW") || return 1
                    OUT="${OUT}${STATUS},${PROP},${VALUE}${NL}"
                    CHANGED=1
                    continue
                fi
                ;;
            *=*)
                KEY=${LINE%%=*}
                RAW=${LINE#*=}
                if [ -n "$KEY" ] && has_generator_token "$RAW"; then
                    VALUE=$(resolve_value "$RAW") || return 1
                    OUT="${OUT}${KEY}=${VALUE}${NL}"
                    CHANGED=1
                    continue
                fi
                ;;
        esac
        OUT="${OUT}${LINE}${NL}"
    done < "$FILE"

    [ "$CHANGED" -eq 1 ] || return 0
    printf '%s' "$OUT" > "$TMP" || { rm -f "$TMP"; return 1; }
    chmod 600 "$TMP" 2>/dev/null
    mv -f "$TMP" "$FILE"
    FREEZE_CONFIG_CHANGED=1
}
