#!/bin/bash
# ---------------------------------------------------------------------------
# Pokemon Fire Ash  --  motor mkxp-z compilado para R36S / ArkOS (ARMv7)
#
# Este archivo va en la RAIZ de /roms/ports  (junto a StardewValley.sh, etc.)
# y la carpeta "mkxp" -- con el motor y los archivos del juego -- al lado.
#
# Esta version incluye un muestreador de diagnostico: escribe en perf-log.txt
# la temperatura, la frecuencia de CPU y la memoria libre cada 5 segundos, para
# poder distinguir por que baja el rendimiento con el paso de los minutos.
# ---------------------------------------------------------------------------
DIR="/roms/ports/mkxp"
LOG="$DIR/mkxp-log.txt"
PERF="$DIR/perf-log.txt"
cd "$DIR" || exit 1

# --- Modo rendimiento ------------------------------------------------------
# Por defecto la consola usa un governor "ondemand"/"schedutil": mantiene la
# CPU baja y solo sube al detectar carga, con retardo. RPG Maker genera carga a
# rafagas (cada evento del mapa ejecuta Ruby en cada fotograma), justo el patron
# que peor detecta ese algoritmo.
#
# OJO: subir la frecuencia tambien sube la temperatura. Si resultase que lo que
# frena el juego es el recorte termico, esto podria empeorarlo -- por eso el
# muestreador de abajo registra temperatura y frecuencia, para poder verlo.
#
# Best-effort: si el sistema no deja escribir, se ignora y el juego arranca.
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
trap restore_governors EXIT
set_performance

# --- Muestreador de diagnostico --------------------------------------------
# Una muestra cada 5 s. El coste es leer cuatro archivos de /proc y /sys, o sea
# nada; puedes borrar este bloque cuando ya no haga falta diagnosticar.
sample_perf() {
    local pid=$1 t f g mem swap rss zone hz cpu prev now
    zone=$(ls /sys/class/thermal/thermal_zone*/temp 2>/dev/null | head -1)
    hz=$(getconf CLK_TCK 2>/dev/null); hz=${hz:-100}
    g=$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_governor \
           /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null | head -1)
    {
        echo "# governor=${g:-?}  nucleos=$(nproc 2>/dev/null)  CLK_TCK=$hz"
        echo "# seg  temp_C  cpu_MHz  cpu_%  mem_libre_MB  swap_MB  rss_MB"
    } > "$PERF"

    # utime+stime en ticks; la diferencia entre muestras dice cuanta CPU real
    # consume el juego. ~100% = un nucleo saturado -> el cuello es la CPU.
    # Muy por debajo con pocos fps -> el cuello esta en la GPU o en la microSD.
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
        swap=$(awk '/^SwapTotal:/{a=$2} /^SwapFree:/{b=$2} END{if(a>0)print int((a-b)/1024); else print 0}' /proc/meminfo 2>/dev/null)
        rss=$(awk '/^VmRSS:/{print int($2/1024)}' /proc/"$pid"/status 2>/dev/null)
        printf '%5d %7d %8d %6d %13s %8s %7s\n' \
            "$s" "$t" "$f" "$cpu" "${mem:-?}" "${swap:-?}" "${rss:-?}" >> "$PERF"
    done
    echo "# fin del muestreo tras ${s}s (el juego termino)" >> "$PERF"
}

# --- Librerias -------------------------------------------------------------
# El motor trae su propia libstdc++ / libgomp / libgcc_s / libruby por si las
# de la consola son mas antiguas. La libc SI es la de la consola (a proposito).
export LD_LIBRARY_PATH="$DIR:$LD_LIBRARY_PATH"

# Sin X11 ni Wayland, KMS/DRM es el modo de dibujar directamente en pantalla.
export SDL_VIDEODRIVER=kmsdrm

# Doble buffer: quita un fotograma de retardo a cambio de algo de rendimiento.
# Desactivado porque ahora el problema es la fluidez, no la latencia.
# export SDL_VIDEO_DOUBLE_BUFFER=1

# Diagnostico SOLO si existe "debug.txt" en esta carpeta: log detallado de SDL
# y muestreo de temperatura/CPU/memoria. Dejarlo activado siempre significa
# escribir en la microSD en cada fotograma, y eso ya ralentiza de por si.
if [ -f "$DIR/debug.txt" ]; then
    export MKXPZ_SDL_DEBUG=1
fi

# --- Lanzamiento -----------------------------------------------------------
./mkxp-z > "$LOG" 2>&1 &
GAME_PID=$!

if [ -f "$DIR/debug.txt" ]; then
    sample_perf "$GAME_PID" &
    PERF_PID=$!
fi

# Devuelve el SELECT+START de siempre para salir a la interfaz de ArkOS: mkxp-z
# lee el mando por SDL y no conoce esa convencion.
if [ -x "$DIR/exitwatch" ]; then
    "$DIR/exitwatch" "$GAME_PID" &
    WATCH_PID=$!
fi

wait "$GAME_PID"
[ -n "$WATCH_PID" ] && kill "$WATCH_PID" 2>/dev/null
[ -n "$PERF_PID" ]  && kill "$PERF_PID"  2>/dev/null

# Red de seguridad: SOLO si el motor aborto por no encontrar tarjeta de sonido,
# reintenta una vez con la salida de audio nula.
if grep -qF "Could not detect an available audio device" "$LOG"; then
    echo "--- reintentando sin audio (ALSOFT_DRIVERS=null) ---" >> "$LOG"
    ALSOFT_DRIVERS=null ./mkxp-z >> "$LOG" 2>&1
fi
