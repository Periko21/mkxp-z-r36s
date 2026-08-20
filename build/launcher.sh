#!/bin/bash
# ---------------------------------------------------------------------------
# Pokemon Fire Ash  --  motor mkxp-z compilado para R36S / ArkOS (ARMv7)
#
# Este archivo va en la RAIZ de /roms/ports  (junto a StardewValley.sh, etc.)
# y la carpeta "mkxp" -- con el motor y los archivos del juego -- al lado.
# ---------------------------------------------------------------------------
DIR="/roms/ports/mkxp"
LOG="$DIR/mkxp-log.txt"
cd "$DIR" || exit 1

# El motor trae su propia libstdc++ / libgomp / libgcc_s / libruby por si las
# de la consola son mas antiguas. La libc SI es la de la consola (a proposito).
export LD_LIBRARY_PATH="$DIR:$LD_LIBRARY_PATH"

# Sin X11 ni Wayland, KMS/DRM es el modo de dibujar directamente en pantalla.
export SDL_VIDEODRIVER=kmsdrm

# Doble buffer: quita un fotograma de retardo entre pulsar y ver, a cambio de
# algo de rendimiento (espera al volcado a pantalla antes de seguir). Queda
# DESACTIVADO porque ahora mismo el problema es la fluidez, no la latencia.
# Para probarlo, descomenta la linea siguiente.
# export SDL_VIDEO_DOUBLE_BUFFER=1

# Log detallado SOLO si existe el archivo "debug.txt" en esta carpeta. Activarlo
# siempre significa escribir en la microSD en cada fotograma, lo que de por si
# ralentiza el juego; crea ese archivo vacio unicamente para diagnosticar.
if [ -f "$DIR/debug.txt" ]; then
    export MKXPZ_SDL_DEBUG=1
fi

# El juego se lanza en segundo plano para poder vigilar la combinacion de
# salida mientras corre.
./mkxp-z > "$LOG" 2>&1 &
GAME_PID=$!

# Devuelve el SELECT+START de siempre para salir a la interfaz de ArkOS: mkxp-z
# lee el mando por SDL y no conoce esa convencion, asi que sin esto la unica
# forma de salir seria resetear la consola.
if [ -x "$DIR/exitwatch" ]; then
    "$DIR/exitwatch" "$GAME_PID" &
    WATCH_PID=$!
fi

wait "$GAME_PID"
[ -n "$WATCH_PID" ] && kill "$WATCH_PID" 2>/dev/null

# Red de seguridad: SOLO si el motor aborto por no encontrar tarjeta de sonido,
# reintenta una vez con la salida de audio nula. Se compara el mensaje exacto y
# fatal, no un fragmento, para no dejar el juego mudo sin motivo.
if grep -qF "Could not detect an available audio device" "$LOG"; then
    echo "--- reintentando sin audio (ALSOFT_DRIVERS=null) ---" >> "$LOG"
    ALSOFT_DRIVERS=null ./mkxp-z >> "$LOG" 2>&1
fi
