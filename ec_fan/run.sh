#!/usr/bin/with-contenv bashio
# Chromebox EC fan as an MQTT device.
#
# The Chrome EC drives the fan from a per-sensor table (fan_off / fan_max, in K).
# thermalset lives in EC RAM only, so any EC reset restores the factory table
# (on fizz boards: fan always on). Every poll compares and reapplies. The user's
# thresholds are MQTT number entities; their retained state topics are the only
# stored copy. If this add-on stops, the EC falls back to its factory table:
# noisy, never hot.
#
# Two modes:
#   fizz     Kench / Teemo / Sion / Wukong / Bleemo (HP Chromebox G2, ASUS Chromebox 3 CN65,
#            Acer Chromebox CXi3, CTL CBx1, ...). The board firmware maps demand % to RPM through
#            a step table with hysteresis, so the entities are "Fan starts at" and
#            "Fan stops at". Tested on Sion.
#   generic  Any other Chrome EC with a fan, opt-in. The entities are the raw EC
#            fan_off ("Fan starts at") and fan_max ("Full speed at"). Many boards
#            replace the linear curve with their own table, so real start and stop
#            points may differ. Untested.

EC="ectool --interface=lpc"
BASE="ec_fan"
AVAIL="${BASE}/availability"
INTERVAL=$(bashio::config 'poll_interval')
FIZZ_DEFAULT_START=46
FIZZ_DEFAULT_STOP=43
MIN_GAP=3
MAX_GAP=18          # fizz: above this the EC's 1 % stop point moves off the stop temperature

bashio::services.available mqtt || bashio::exit.nok "No MQTT service; install the Mosquitto broker add-on"
MQ=(-h "$(bashio::services mqtt host)" -p "$(bashio::services mqtt port)"
    -u "$(bashio::services mqtt username)" -P "$(bashio::services mqtt password)")

pub() { mosquitto_pub "${MQ[@]}" "$@" || bashio::log.warning "MQTT publish failed: $*"; }
# -W timeout exits non-zero when nothing is retained; bashio runs with errexit
retained() { mosquitto_sub "${MQ[@]}" -t "$1" -C 1 -W 3 2>/dev/null || true; }
is_int() { [[ "$1" =~ ^[0-9]+$ ]]; }

# ---------------------------------------------------------------- detect
$EC version >/dev/null 2>&1 || bashio::exit.nok "ectool cannot reach the EC over LPC. Is this a Chromebox running coreboot (MrChromebox) firmware?"
EC_VERSION=$($EC version 2>/dev/null | awk -F': *' '/^RW version/ { print $2 }' || true)
EC_BOARD=${EC_VERSION%%_v*}
OEM_ID=$($EC cbi get 1 2>/dev/null | awk '/^As uint/ { print $3 }' || true)
NUM_FANS=$($EC pwmgetnumfans 2>/dev/null | awk '{ print $NF }' || true)
PRODUCT=$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)
PRODUCT=${PRODUCT:-$EC_BOARD}
bashio::log.info "EC ${EC_VERSION:-unknown}, board ${EC_BOARD:-unknown}, OEM id ${OEM_ID:-none}, product ${PRODUCT:-unknown}, fans ${NUM_FANS:-?}"

[[ "${NUM_FANS:-0}" == "0" ]] && bashio::exit.nok "The EC reports no fan (fanless model such as Jax), nothing to control"

# fizz OEM ids from board/fizz/board.h: 0 Kench, 1 Teemo, 2 Sion, 3-5 Wukong, 6 Bleemo.
# 8 Jax has no fan; 10 Excelsior uses a different stop point, so it goes generic.
if [[ "$EC_BOARD" == "fizz" ]] && is_int "${OEM_ID:-x}" && (( OEM_ID <= 6 )); then
    MODE=fizz
elif bashio::config.true 'experimental_other_boards'; then
    MODE=generic
    bashio::log.warning "Board ${EC_BOARD} (${PRODUCT}) is not a tested fizz board; running in experimental generic mode"
else
    bashio::log.info "EC thermal table on this board:"
    $EC thermalget 2>&1 | while read -r l; do bashio::log.info "  $l"; done || true
    bashio::exit.nok "Board ${EC_BOARD:-unknown} (${PRODUCT}) is not supported yet. Enable 'experimental_other_boards' to try generic mode, and please open an issue with the log above."
fi

# EC sensor table: index, high K, fan_off K, fan_max K, name
declare -a S_IDX=() S_HIGH=() S_OFF=() S_MAX=() S_NAME=()
while read -r i warn high halt off max name; do
    S_IDX+=("$i"); S_HIGH+=("$high"); S_OFF+=("$off"); S_MAX+=("$max"); S_NAME+=("$name")
done < <($EC thermalget 2>/dev/null | awk '$1 ~ /^[0-9]+$/ { print $1, $2, $3, $4, $5, $6, $7 }' || true)
(( ${#S_IDX[@]} > 0 )) || bashio::exit.nok "EC thermalget returned no sensors"

if bashio::config.has_value 'fan_sensor'; then
    FAN_SENSOR=$(bashio::config 'fan_sensor')
elif [[ "$MODE" == fizz ]]; then
    FAN_SENSOR=0
else
    FAN_SENSOR=${S_IDX[0]}
    for n in "${!S_IDX[@]}"; do
        if (( S_MAX[n] > 0 )); then FAN_SENSOR=${S_IDX[n]}; break; fi
    done
fi
FAN_N=-1
for n in "${!S_IDX[@]}"; do [[ "${S_IDX[n]}" == "$FAN_SENSOR" ]] && FAN_N=$n; done
(( FAN_N >= 0 )) || bashio::exit.nok "fan_sensor ${FAN_SENSOR} does not exist on this EC"
HIGH_C=$(( S_HIGH[FAN_N] > 0 ? S_HIGH[FAN_N] - 273 : 80 ))
bashio::log.info "Mode ${MODE}; fan follows EC sensor ${FAN_SENSOR} (${S_NAME[FAN_N]}), high limit ${HIGH_C} C"

# ---------------------------------------------------------------- threshold model
# fizz (board/fizz/board.c, fan_step_1_1 tables):
#   demand % = 100 * (t - fan_off) / (fan_max - fan_off), integer K
#   the fan starts at >= 36 % and stops again only near 0 %
# So fan_off = stop temperature, and the span is the largest one where the
# start temperature is the first to reach 36 %. Full speed is ~98 %.
# Verified on Sion by simulating the EC table for every start/stop pair 3 to 18 C apart.
# generic: A = fan_off (fan starts), B = fan_max (full speed), applied as is.
if [[ "$MODE" == fizz ]]; then
    KEY_A=fan_start; NAME_A="Fan starts at"; RANGE_A=(30 75); ICON_A=mdi:thermometer-chevron-up
    KEY_B=fan_stop;  NAME_B="Fan stops at";  RANGE_B=(25 70); ICON_B=mdi:thermometer-chevron-down
else
    KEY_A=fan_start; NAME_A="Fan starts at"; RANGE_A=(20 80); ICON_A=mdi:thermometer-chevron-up
    KEY_B=fan_full;  NAME_B="Full speed at"; RANGE_B=(25 95); ICON_B=mdi:thermometer-high
fi

derive() {
    if [[ "$MODE" == fizz ]]; then
        local span=$((100 * (A - B) / 36))
        OFF_K=$((B + 273))
        MAX_K=$((OFF_K + span))
        FULL=$((B + (98 * span + 99) / 100))
        SUMMARY="Fan starts at ${A} C, stops at ${B} C, full speed at ${FULL} C"
    else
        OFF_K=$((A + 273))
        MAX_K=$((B + 273))
        SUMMARY="EC fan_off ${A} C, fan_max ${B} C"
    fi
}

valid_pair() {
    # $1 A, $2 B
    if [[ "$MODE" == fizz ]]; then
        local span=$((100 * ($1 - $2) / 36))
        (( $1 - $2 >= MIN_GAP && $1 - $2 <= MAX_GAP && $2 + span < HIGH_C ))
    else
        (( $2 - $1 >= MIN_GAP && $2 < HIGH_C ))
    fi
}

rule_text() {
    if [[ "$MODE" == fizz ]]; then
        echo "start must be ${MIN_GAP} to ${MAX_GAP} C above stop, and full speed below ${HIGH_C} C"
    else
        echo "full speed must be at least ${MIN_GAP} C above start, and below ${HIGH_C} C"
    fi
}

A=$(retained "${BASE}/${KEY_A}/state")
B=$(retained "${BASE}/${KEY_B}/state")
if ! is_int "$A" || ! is_int "$B" || ! valid_pair "$A" "$B"; then
    if [[ "$MODE" == fizz ]]; then
        A=$FIZZ_DEFAULT_START; B=$FIZZ_DEFAULT_STOP
    else
        # start from what the EC already does, so installing changes nothing
        A=$(( S_OFF[FAN_N] > 0 ? S_OFF[FAN_N] - 273 : 40 ))
        B=$(( S_MAX[FAN_N] > 0 ? S_MAX[FAN_N] - 273 : 60 ))
        valid_pair "$A" "$B" || { A=40; B=60; }
    fi
fi
derive

# ---------------------------------------------------------------- discovery
DEV_ID="ec_fan_$(tr -cs 'A-Za-z0-9' '_' <<< "${PRODUCT,,}" | sed 's/_*$//')"
DEVICE=$(jq -nc --arg id "$DEV_ID" --arg sw "$EC_VERSION" --arg model "${PRODUCT} (${EC_BOARD} EC)" \
    '{identifiers: [$id], name: "Chromebox", manufacturer: "Google", model: $model, sw_version: $sw}')

discover() {
    # $1 component, $2 object id, $3 extra JSON
    local cfg
    cfg=$(jq -nc --arg id "$2" --arg comp "$1" --arg avail "$AVAIL" --argjson dev "$DEVICE" --argjson x "$3" \
        '{unique_id: ("ec_fan_" + $id), default_entity_id: ($comp + ".chromebox_" + $id),
          availability_topic: $avail, device: $dev} + $x')
    pub -r -t "homeassistant/$1/ec_fan/$2/config" -m "$cfg"
}

state_sensor() {
    # $1 object id, $2 jq path into the state JSON, $3 extra JSON
    discover sensor "$1" "$(jq -nc --arg k "$2" --arg t "${BASE}/state" --argjson x "$3" \
        '{state_topic: $t, value_template: ("{{ value_json." + $k + " }}")} + $x')"
}

TEMP='"unit_of_measurement":"°C","device_class":"temperature","state_class":"measurement","suggested_display_precision":0'
state_sensor fan_speed rpm \
    '{"name":"Fan speed","unit_of_measurement":"rpm","state_class":"measurement","icon":"mdi:fan"}'
# The CPU's own package sensor (coretemp / k10temp); the EC cannot read it, so it is display only
state_sensor cpu_temperature cpu "{\"name\":\"CPU temperature\",${TEMP}}"
for n in "${!S_IDX[@]}"; do
    if [[ "$MODE" == fizz ]]; then
        label="Board temperature $((n + 1))"
    else
        label="EC ${S_NAME[n]}"
    fi
    state_sensor "board_temperature_$((n + 1))" "t[$n]" "{\"name\":\"${label}\",${TEMP}}"
done

threshold_number() {
    # $1 key, $2 name, $3 min, $4 max, $5 icon
    discover number "${1}_temperature" "$(jq -nc --arg n "$2" --argjson lo "$3" --argjson hi "$4" --arg i "$5" \
        --arg c "${BASE}/${1}/set" --arg s "${BASE}/${1}/state" \
        '{name: $n, command_topic: $c, state_topic: $s, min: $lo, max: $hi, step: 1, mode: "box",
          unit_of_measurement: "°C", device_class: "temperature", entity_category: "config", icon: $i}')"
}
threshold_number "$KEY_A" "$NAME_A" "${RANGE_A[0]}" "${RANGE_A[1]}" "$ICON_A"
threshold_number "$KEY_B" "$NAME_B" "${RANGE_B[0]}" "${RANGE_B[1]}" "$ICON_B"

publish_thresholds() {
    pub -r -t "${BASE}/${KEY_A}/state" -m "$A"
    pub -r -t "${BASE}/${KEY_B}/state" -m "$B"
}

# ---------------------------------------------------------------- EC
set_sensor() {
    # $1 sensor index, $2 fan_off K, $3 fan_max K. warn/high/halt are kept as read.
    local row warn high halt off max
    row=$($EC thermalget 2>/dev/null | awk -v i="$1" '$1 == i { print $2, $3, $4, $5, $6 }' || true)
    if [[ -z "$row" ]]; then
        bashio::log.warning "EC thermalget read failed for sensor $1"
        return
    fi
    read -r warn high halt off max <<< "$row"
    [[ "$off" == "$2" && "$max" == "$3" ]] && return
    if $EC thermalset "$1" "$warn" "$high" "$halt" "$2" "$3" >/dev/null 2>&1; then
        bashio::log.info "EC sensor $1 fan table was ${off} K / ${max} K; set to $2 K / $3 K (warn ${warn}, high ${high}, halt ${halt} kept)"
    else
        bashio::log.error "EC thermalset failed for sensor $1"
    fi
}

enforce() {
    set_sensor "$FAN_SENSOR" "$OFF_K" "$MAX_K"
    # The EC runs the fan at the highest demand across sensors. On fizz the other
    # sensors are zeroed ("ignore for the fan") so only the chosen one drives it.
    # Generic mode leaves them alone: on other boards they may be the CPU sensor.
    if [[ "$MODE" == fizz ]]; then
        for i in "${S_IDX[@]}"; do
            [[ "$i" == "$FAN_SENSOR" ]] || set_sensor "$i" 0 0
        done
    fi
}

read_cpu() {
    local hw
    hw=$(grep -l -E '^(coretemp|k10temp)$' /sys/class/hwmon/hwmon*/name 2>/dev/null | head -n 1 || true)
    [[ -n "$hw" ]] && echo $(( $(cat "${hw%/name}/temp1_input" 2>/dev/null || echo 0) / 1000 ))
    return 0
}

publish_state() {
    local temps rpm cpu tjson
    temps=$($EC temps all 2>/dev/null || true)
    rpm=$($EC pwmgetfanrpm 2>/dev/null | awk '/RPM:/ { print $NF; exit }' || true)
    cpu=$(read_cpu)
    tjson=$(for name in "${S_NAME[@]}"; do
                awk -v s="$name" '$1 == s && $3 == "K" { v = $2 - 273 } END { print (v == "" ? "null" : v) }' <<< "$temps"
            done | jq -sc '.')
    if ! is_int "${rpm:-x}" || [[ "$(jq 'all(. == null)' <<< "${tjson:-[]}")" == "true" ]]; then
        bashio::log.warning "EC sensor read failed"
        return
    fi
    pub -t "${BASE}/state" -m "$(jq -nc --argjson rpm "$rpm" --argjson t "$tjson" --argjson cpu "${cpu:-null}" \
        '{rpm: $rpm, t: $t, cpu: $cpu}')"
}

handle_set() {
    # $1 topic, $2 payload (HA may send "40.0")
    local key=${1#"${BASE}/"} v=${2%%.*}
    key=${key%/set}
    local a=$A b=$B
    if ! is_int "$v"; then
        bashio::log.warning "Ignoring non-numeric ${key}: $2"
    else
        [[ "$key" == "$KEY_A" ]] && a=$v
        [[ "$key" == "$KEY_B" ]] && b=$v
        if valid_pair "$a" "$b"; then
            A=$a
            B=$b
            derive
            bashio::log.info "$SUMMARY"
        else
            bashio::log.warning "Rejected ${key}=${v}: $(rule_text)"
        fi
    fi
    publish_thresholds
    enforce
    publish_state
}

# ---------------------------------------------------------------- main
FIFO=/tmp/ec_fan_cmd
rm -f "$FIFO" && mkfifo "$FIFO"
exec 3<>"$FIFO"
mosquitto_sub "${MQ[@]}" -v -t "${BASE}/+/set" \
    --will-topic "$AVAIL" --will-payload offline --will-retain >&3 &
SUB=$!
trap 'pub -r -t "$AVAIL" -m offline; kill $SUB 2>/dev/null; exit 0' TERM INT

sleep 1
pub -r -t "$AVAIL" -m online
publish_thresholds
bashio::log.info "${SUMMARY}, poll ${INTERVAL} s"

next=0
while true; do
    kill -0 "$SUB" 2>/dev/null || bashio::exit.nok "MQTT subscriber exited"
    now=$(date +%s)
    if (( now >= next )); then
        enforce
        publish_state
        next=$((now + INTERVAL))
    fi
    wait_s=$((next - $(date +%s)))
    (( wait_s < 1 )) && wait_s=1
    if read -r -t "$wait_s" topic payload <&3; then
        handle_set "$topic" "$payload"
    fi
done
