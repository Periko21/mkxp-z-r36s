#!/bin/bash
# ---------------------------------------------------------------------------
# Pokemon Infinite Fusion  --  motor mkxp-z compilado para R36S / ArkOS (ARMv7)
#
# Instalacion PARALELA a la de Fire Ash. Este archivo va en la raiz de
# /roms/ports  y los archivos del juego en  /roms/ports/mkxp-fusion/.
#
# Novedad de esta version: ZRAM. La consola no trae ningun espacio de
# intercambio, asi que cuando se acaba la RAM el kernel mata el juego sin
# avisar -- que es exactamente lo que estaba pasando. zram crea un swap
# comprimido dentro de la propia RAM: las paginas frias se guardan
# comprimidas (2:1 o mejor con datos de imagenes) y el juego gana margen.
#
# NO cura la fuga de memoria del juego, solo compra tiempo. Y comprimir
# cuesta CPU, que aqui ya es el cuello de botella.
#
# Archivos opcionales, dentro de mkxp-fusion:
#   debug.txt  -> log detallado de SDL + muestreo de rendimiento cada 5 s.
#   hora.txt   -> hora simulada solo para este juego ("22:00").
#   sin-zram.txt -> desactiva el zram, para comparar con y sin.
# ---------------------------------------------------------------------------
DIR="/roms/ports/mkxp-fusion"
LOG="$DIR/mkxp-log.txt"
PERF="$DIR/perf-log.txt"
QLOG="$DIR/guardados-apartados.txt"
MARK="$DIR/exitwatch-marker.txt"
ZRAM_MB=512
cd "$DIR" || exit 1

rm -f "$MARK"

# --- Guardados corruptos ---------------------------------------------------
quarantine_broken_saves() {
    local q="$DIR/saves-corruptas" f base dest n=0
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        mkdir -p "$q" 2>/dev/null || return 0
        base=$(echo "${f#$DIR/}" | tr '/' '_')
        dest="$q/$base"
        [ -e "$dest" ] && dest="$q/$(date +%Y%m%d-%H%M%S)-$base"
        if mv -f "$f" "$dest" 2>/dev/null; then
            n=$((n+1))
            echo "$(date '+%Y-%m-%d %H:%M:%S')  apartado (0 bytes): ${f#$DIR/}" >> "$QLOG"
        fi
    done < <(find "$DIR" -path "$DIR/Data" -prune -o \
                        -path "$q" -prune -o \
                        -type f -size 0 \( -name '*.rxdata' -o -name '*.dat' \) -print 2>/dev/null)
    if [ "$n" -gt 0 ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S')  total apartados: $n" >> "$QLOG"
        sync
    fi
    return 0
}
quarantine_broken_saves

# --- Memoria comprimida (zram) ---------------------------------------------
# Best-effort de principio a fin: si algo falla, el juego arranca igual y en
# el log queda escrito por donde se torcio.
ZRAM_ESTADO="no intentado"
ZRAM_MIO=0
ZRAM_SU=""

setup_zram() {
    local ya

    if [ -f "$DIR/sin-zram.txt" ]; then
        ZRAM_ESTADO="desactivado a mano (existe sin-zram.txt)"
        return 0
    fi

    ya=$(awk '/^SwapTotal:/{print $2}' /proc/meminfo 2>/dev/null)
    if [ "${ya:-0}" -gt 0 ] 2>/dev/null; then
        ZRAM_ESTADO="ya habia swap ($((ya/1024)) MB); no toco nada"
        return 0
    fi

    # ArkOS NO lanza los ports como root, asi que hay que pasar por sudo.
    # "-n" = no preguntar nunca la contrasena: si hiciera falta, falla y
    # seguimos sin zram en vez de dejar el juego colgado esperando a nadie.
    if [ "$(id -u)" = "0" ]; then
        ZRAM_SU=""
    elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        ZRAM_SU="sudo -n"
    else
        ZRAM_ESTADO="sin permisos: el port no es root y sudo pide contrasena"
        return 0
    fi

    if [ ! -e /sys/block/zram0 ]; then
        $ZRAM_SU modprobe zram num_devices=1 2>/dev/null
        sleep 1
    fi
    if [ ! -e /sys/block/zram0 ]; then
        ZRAM_ESTADO="este kernel no trae zram"
        return 0
    fi

    # Orden obligatorio: soltar, resetear, algoritmo, tamano, formatear, activar.
    # Los redireccionamientos los hace el shell, no sudo, asi que cada escritura
    # a /sys va envuelta en su propio sh -c o se escribiria sin privilegios.
    $ZRAM_SU swapoff /dev/zram0 2>/dev/null
    $ZRAM_SU sh -c 'echo 1 > /sys/block/zram0/reset' 2>/dev/null
    $ZRAM_SU sh -c 'echo lz4 > /sys/block/zram0/comp_algorithm' 2>/dev/null
    if ! $ZRAM_SU sh -c "echo $((ZRAM_MB * 1024 * 1024)) > /sys/block/zram0/disksize" 2>/dev/null; then
        ZRAM_ESTADO="no me deja fijar el tamano de zram0"
        return 0
    fi
    if ! $ZRAM_SU mkswap /dev/zram0 >/dev/null 2>&1; then
        ZRAM_ESTADO="mkswap fallo sobre zram0"
        return 0
    fi
    $ZRAM_SU swapon /dev/zram0 2>/dev/null

    # No me fio del codigo de salida: compruebo que de verdad esta montado.
    if ! grep -q zram0 /proc/swaps 2>/dev/null; then
        ZRAM_ESTADO="swapon no llego a montar zram0"
        return 0
    fi

    ZRAM_MIO=1
    # Con zram interesa que el kernel intercambie pronto y sin leer de mas:
    # comprimir en RAM es mucho mas barato que quedarse sin memoria.
    $ZRAM_SU sh -c 'echo 100 > /proc/sys/vm/swappiness' 2>/dev/null
    $ZRAM_SU sh -c 'echo 0 > /proc/sys/vm/page-cluster' 2>/dev/null
    ZRAM_ESTADO="activo, ${ZRAM_MB} MB comprimidos ($(cat /sys/block/zram0/comp_algorithm 2>/dev/null | tr -d '\n'))${ZRAM_SU:+ [via sudo]}"
    return 0
}
setup_zram

# --- Hora simulada (opcional) ----------------------------------------------
GAME_TZ=""
compute_game_tz() {
    local want wh wm want_min now_min off sign_off oh om cur_off diff total sign hh mm
    want=$(printf '%s' "$1" | tr -d '[:space:]\r')
    [[ "$want" =~ ^([0-9]{1,2})(:([0-9]{1,2}))?$ ]] || return 1
    wh=$((10#${BASH_REMATCH[1]})); wm=$((10#${BASH_REMATCH[3]:-0}))
    { [ "$wh" -gt 23 ] || [ "$wm" -gt 59 ]; } && return 1
    want_min=$((wh*60 + wm))
    now_min=$(( 10#$(date +%H)*60 + 10#$(date +%M) ))
    cur_off=$(date +%z)
    sign_off=${cur_off:0:1}; oh=$((10#${cur_off:1:2})); om=$((10#${cur_off:3:2}))
    off=$((oh*60 + om)); [ "$sign_off" = "-" ] && off=$((-off))
    diff=$(( ( (want_min - now_min) % 1440 + 1440 ) % 1440 ))
    total=$(( ( (off + diff) % 1440 + 1440 ) % 1440 ))
    [ "$total" -gt 720 ] && total=$((total - 1440))
    if [ "$total" -ge 0 ]; then sign="-"; else sign="+"; total=$((-total)); fi
    hh=$((total/60)); mm=$((total%60))
    GAME_TZ=$(printf 'GAME%s%d:%02d' "$sign" "$hh" "$mm")
    return 0
}

HORA_NOTA=""
if [ -s "$DIR/hora.txt" ]; then
    if compute_game_tz "$(head -1 "$DIR/hora.txt")"; then
        export TZ="$GAME_TZ"
        HORA_NOTA="--- hora simulada: el juego cree que son las $(date +%H:%M) (TZ=$GAME_TZ) ---"
    else
        HORA_NOTA="--- AVISO: hora.txt no se entiende; se usa la hora real. Formato: 22:00 ---"
    fi
fi

# --- Modo rendimiento ------------------------------------------------------
SAVED_GOV=""
set_performance() {
    local f orig
    for f in /sys/devices/system/cpu/cpufreq/policy*/scaling_governor \
             /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor \
             /sys/class/devfreq/*/governor; do
        [ -w "$f" ] || continue
        orig=$(cat "$f" 2>/dev/null) || continue
        [ "$orig" = "performance" ] && continue
        if echo performance > "$f" 2>/dev/null; then
            SAVED_GOV="$SAVED_GOV$f|$orig"$'\n'
        fi
    done
}
restore_governors() {
    local f orig
    while IFS='|' read -r f orig; do
        [ -n "$f" ] && [ -w "$f" ] && echo "$orig" > "$f" 2>/dev/null
    done <<< "$SAVED_GOV"
}
cleanup() {
    restore_governors
    sync
    # Solo desmonto el zram si lo monte yo, para no pisar nada del sistema.
    [ "$ZRAM_MIO" = "1" ] && $ZRAM_SU swapoff /dev/zram0 2>/dev/null
    return 0
}
trap cleanup EXIT
set_performance

# --- Muestreador de diagnostico --------------------------------------------
sample_perf() {
    local pid=$1 t f g mem swap rss zone hz cpu prev now
    zone=$(ls /sys/class/thermal/thermal_zone*/temp 2>/dev/null | head -1)
    hz=$(getconf CLK_TCK 2>/dev/null); hz=${hz:-100}
    g=$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_governor \
           /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null | head -1)
    {
        echo "# $(date '+%Y-%m-%d %H:%M:%S')  juego=infinite-fusion"
        echo "# zram: $ZRAM_ESTADO"
        echo "# governor=${g:-?}  nucleos=$(nproc 2>/dev/null)  CLK_TCK=$hz"
        echo "# seg  temp_C  cpu_MHz  cpu_%  mem_libre_MB  swap_MB  rss_MB"
    } > "$PERF"
    prev=$(awk '{print $14+$15}' /proc/"$pid"/stat 2>/dev/null); prev=${prev:-0}
    local s=0
    while [ -d "/proc/$pid" ]; do
        sleep 5
        s=$((s+5))
        t=$(cat "$zone" 2>/dev/null); t=$(( ${t:-0} / 1000 ))
        f=$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_cur_freq \
               /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null | head -1)
        f=$(( ${f:-0} / 1000 ))
        now=$(awk '{print $14+$15}' /proc/"$pid"/stat 2>/dev/null); now=${now:-$prev}
        cpu=$(( (now - prev) * 100 / (5 * hz) )); prev=$now
        mem=$(awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo 2>/dev/null)
        # swap USADO, que con zram es justo lo que queremos vigilar
        swap=$(awk '/^SwapTotal:/{a=$2} /^SwapFree:/{b=$2} END{if(a>0)print int((a-b)/1024); else print 0}' /proc/meminfo 2>/dev/null)
        rss=$(awk '/^VmRSS:/{print int($2/1024)}' /proc/"$pid"/status 2>/dev/null)
        printf '%5d %7d %8d %6d %13s %8s %7s\n' \
            "$s" "$t" "$f" "$cpu" "${mem:-?}" "${swap:-?}" "${rss:-?}" >> "$PERF"
    done
    echo "# fin del muestreo tras ${s}s (el juego termino)" >> "$PERF"
}

# --- Librerias -------------------------------------------------------------
export LD_LIBRARY_PATH="$DIR:$LD_LIBRARY_PATH"
export SDL_VIDEODRIVER=kmsdrm

if [ -f "$DIR/debug.txt" ]; then
    export MKXPZ_SDL_DEBUG=1
fi

# --- Lanzamiento -----------------------------------------------------------
: > "$LOG"
echo "=== inicio: $(date '+%Y-%m-%d %H:%M:%S') ===" >> "$LOG"
echo "=== zram: $ZRAM_ESTADO ===" >> "$LOG"
[ -n "$HORA_NOTA" ] && echo "$HORA_NOTA" >> "$LOG"
if [ -f "$DIR/debug.txt" ]; then
    echo "=== debug.txt presente: se generara perf-log.txt ===" >> "$LOG"
else
    echo "=== SIN debug.txt: NO habra perf-log.txt en esta partida ===" >> "$LOG"
fi

./mkxp-z >> "$LOG" 2>&1 &
GAME_PID=$!

if [ -f "$DIR/debug.txt" ]; then
    sample_perf "$GAME_PID" &
    PERF_PID=$!
fi

if [ -x "$DIR/exitwatch" ]; then
    "$DIR/exitwatch" "$GAME_PID" "$MARK" &
    WATCH_PID=$!
fi

wait "$GAME_PID"
RC=$?

[ -n "$WATCH_PID" ] && kill "$WATCH_PID" 2>/dev/null
[ -n "$PERF_PID" ]  && kill "$PERF_PID"  2>/dev/null

sync

# --- Post-mortem -----------------------------------------------------------
{
    echo ""
    echo "=== POST-MORTEM  $(date '+%Y-%m-%d %H:%M:%S') ==="
    echo "codigo de salida del motor: $RC"
    case "$RC" in
        0)   echo "  -> salida normal, el juego se cerro solo" ;;
        134) echo "  -> 134 = SIGABRT: el motor aborto por un error interno" ;;
        137) echo "  -> 137 = SIGKILL: alguien MATO el proceso sin avisar." ;;
        139) echo "  -> 139 = SIGSEGV: fallo de segmentacion del motor" ;;
        143) echo "  -> 143 = SIGTERM: se pidio cerrar (SELECT+START) y obedecio" ;;
        *)   echo "  -> codigo poco habitual; si es >128, la senal fue $((RC-128))" ;;
    esac

    if [ -f "$MARK" ]; then
        echo "marcador de exitwatch: $(cat "$MARK")"
    else
        echo "marcador de exitwatch: NINGUNO"
        echo "  -> el combo SELECT+START NO intervino: si el codigo es 137, lo mato el sistema"
    fi

    echo "zram: $ZRAM_ESTADO"
    if [ -e /sys/block/zram0/mm_stat ]; then
        echo "zram mm_stat (datos_originales comprimidos memoria_usada ...):"
        echo "  $(cat /sys/block/zram0/mm_stat 2>/dev/null)"
    fi
    echo "swap total: $(awk '/^SwapTotal:/{print int($2/1024)}' /proc/meminfo 2>/dev/null) MB"
    echo "swap usado al terminar: $(awk '/^SwapTotal:/{a=$2} /^SwapFree:/{b=$2} END{print int((a-b)/1024)}' /proc/meminfo 2>/dev/null) MB"
    echo "memoria libre al terminar: $(awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo 2>/dev/null) MB"

    echo "--- mensajes del kernel sobre falta de memoria ---"
    if dmesg >/dev/null 2>&1; then
        dmesg 2>/dev/null | grep -iE 'out of memory|killed process|oom-kill|oom_reaper' | tail -6
        echo "  (si no aparece nada arriba, el kernel NO mato el juego por memoria)"
    else
        echo "  (dmesg no accesible sin root en esta consola)"
    fi
    echo "=== fin del post-mortem ==="
} >> "$LOG"

sync

if grep -qF "Could not detect an available audio device" "$LOG"; then
    echo "--- reintentando sin audio (ALSOFT_DRIVERS=null) ---" >> "$LOG"
    ALSOFT_DRIVERS=null ./mkxp-z >> "$LOG" 2>&1
    sync
fi
