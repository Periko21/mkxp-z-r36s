#!/bin/bash
# ---------------------------------------------------------------------------
# CambiarHora.sh  --  cambiar la hora y la fecha de la consola desde la propia
#                     R36S, sin PC, sin wifi y sin PortMaster.
#
# Va en /roms/ports/  y aparece en el menu "Ports" como "CambiarHora".
#
# Para que sirve: Pokemon Essentials decide si es de dia o de noche mirando el
# reloj del sistema. Poniendo la consola a las 22:00 el juego cree que es de
# noche. No toca el juego ni el launcher para nada.
#
# Basado en el patron estandar de los scripts de ArkOS (/opt/inttools/gptokeyb
# + dialog), no en PortMaster, que esta consola no tiene por que llevar.
# ---------------------------------------------------------------------------

# --- Root ------------------------------------------------------------------
# Cambiar el reloj requiere root. ArkOS permite sudo sin contrasena.
if [ "$(id -u)" -ne 0 ]; then
    exec sudo -- "$0" "$@"
fi

SCRIPT_PATH=$(readlink -f "$0")
SCRIPT_NAME=$(basename "$SCRIPT_PATH")

# --- Pantalla --------------------------------------------------------------
# EmulationStation deja el script en una consola de texto. Cual exactamente
# varia entre versiones de ArkOS, asi que se busca en vez de darla por hecha.
CURR_TTY=""
for c in "$(tty 2>/dev/null)" /dev/tty1 /dev/tty0 /dev/console; do
    if [ -c "$c" ] && [ -w "$c" ]; then CURR_TTY="$c"; break; fi
done
[ -n "$CURR_TTY" ] || CURR_TTY=/dev/tty1

exec > "$CURR_TTY" 2>&1
printf "\033c" > "$CURR_TTY"
export TERM=linux
export XDG_RUNTIME_DIR="/run/user/$(id -u)"

# --- Mando -----------------------------------------------------------------
# dialog espera un teclado; gptokeyb convierte el mando en uno. Si no esta,
# el script sigue funcionando: se puede navegar por SSH con un teclado real.
pkill -9 -f gptokeyb 2>/dev/null || true
if [ -f "/opt/inttools/gptokeyb" ]; then
    [ -e /dev/uinput ] && chmod 666 /dev/uinput 2>/dev/null || true
    export SDL_GAMECONTROLLERCONFIG_FILE="/opt/inttools/gamecontrollerdb.txt"
    /opt/inttools/gptokeyb -1 "$SCRIPT_NAME" -c "/opt/inttools/keys.gptk" \
        >/dev/null 2>&1 &
fi

ExitScript() {
    pkill -f "gptokeyb -1 $SCRIPT_NAME" 2>/dev/null || true
    printf "\033c\e[?25h" > "$CURR_TTY"
    exit 0
}
trap ExitScript EXIT SIGINT SIGTERM
printf "\e[?25l" > "$CURR_TTY"

if ! command -v dialog >/dev/null 2>&1; then
    printf "\033c" > "$CURR_TTY"
    echo "Falta 'dialog'. Conecta el wifi y ejecuta:  sudo apt install dialog"
    sleep 8
    ExitScript
fi

# --- Reloj -----------------------------------------------------------------

# Si el wifi esta encendido, el sincronizado automatico devuelve la hora real a
# los pocos segundos y parece que el script "no funciona". Por eso se apaga
# antes de tocar nada, y hay una opcion para volver a encenderlo.
ntp_activo() {
    command -v timedatectl >/dev/null 2>&1 || return 1
    timedatectl show -p NTP --value 2>/dev/null | grep -qi '^yes$'
}
ntp_off() {
    command -v timedatectl >/dev/null 2>&1 && timedatectl set-ntp false >/dev/null 2>&1
    systemctl stop systemd-timesyncd >/dev/null 2>&1
    return 0
}
ntp_on() {
    command -v timedatectl >/dev/null 2>&1 && timedatectl set-ntp true >/dev/null 2>&1
    systemctl start systemd-timesyncd >/dev/null 2>&1
    return 0
}

# La R36S no lleva pila de reloj, asi que normalmente no hay /dev/rtc y este
# paso no hace nada. Se intenta igual por si tu unidad si la tiene.
guardar_en_rtc() {
    [ -e /dev/rtc ] || [ -e /dev/rtc0 ] || return 0
    hwclock --systohc --utc >/dev/null 2>&1
    return 0
}

# $1 = "HH:MM" o "HH:MM:SS". Cambia SOLO la hora, respetando la fecha.
poner_hora() {
    local h="$1"
    case "$h" in
        [0-9][0-9]:[0-9][0-9])    h="$h:00" ;;
        [0-9][0-9]:[0-9][0-9]:[0-9][0-9]) ;;
        *) return 1 ;;
    esac
    ntp_off
    date +%T -s "$h" >/dev/null 2>&1 || return 1
    guardar_en_rtc
    sync
    return 0
}

# $1 = "YYYY-MM-DD". Cambia SOLO la fecha, respetando la hora.
poner_fecha() {
    local d="$1" ahora
    case "$d" in
        [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
        *) return 1 ;;
    esac
    ahora=$(date +%H:%M:%S)
    ntp_off
    date -s "$d $ahora" >/dev/null 2>&1 || return 1
    guardar_en_rtc
    sync
    return 0
}

aviso() {
    dialog --backtitle "R36S" --title "$1" --msgbox "$2" 8 52
}

# --- Menu ------------------------------------------------------------------
while true; do
    if ntp_activo; then estado="sincronizacion automatica: ACTIVADA"
    else                estado="sincronizacion automatica: apagada"; fi

    CHOICE=$(dialog --backtitle "R36S  --  hora del sistema" \
        --title "$(date '+%A %d/%m/%Y   %H:%M:%S')" \
        --cancel-label "Salir" \
        --output-fd 1 \
        --menu "$estado" 17 56 9 \
        1 "Noche      (22:00)" \
        2 "Dia        (12:00)" \
        3 "Amanecer   (07:00)" \
        4 "Atardecer  (18:00)" \
        5 "Madrugada  (03:00)" \
        6 "Elegir hora exacta..." \
        7 "Cambiar la fecha..." \
        8 "Volver a la hora real (wifi)" \
        9 "Salir") || ExitScript

    case "$CHOICE" in
        1) poner_hora "22:00" && aviso "Listo" "Son las 22:00. En el juego sera de NOCHE." ;;
        2) poner_hora "12:00" && aviso "Listo" "Son las 12:00. En el juego sera de DIA." ;;
        3) poner_hora "07:00" && aviso "Listo" "Son las 07:00. Amanecer." ;;
        4) poner_hora "18:00" && aviso "Listo" "Son las 18:00. Atardecer." ;;
        5) poner_hora "03:00" && aviso "Listo" "Son las 03:00. Noche cerrada." ;;
        6)
            T=$(dialog --backtitle "R36S" --title "Hora" --output-fd 1 \
                       --timebox "Izquierda/derecha para cambiar de campo" 0 0) || continue
            if poner_hora "$T"; then
                aviso "Listo" "Hora puesta a $(date +%H:%M)."
            else
                aviso "Error" "No he podido aplicar esa hora."
            fi
            ;;
        7)
            D=$(dialog --backtitle "R36S" --title "Fecha" --date-format "%Y-%m-%d" \
                       --output-fd 1 \
                       --calendar "Izquierda/derecha para moverte" 0 0) || continue
            if poner_fecha "$D"; then
                aviso "Listo" "Fecha puesta a $(date +%d/%m/%Y)."
            else
                aviso "Error" "No he podido aplicar esa fecha."
            fi
            ;;
        8)
            ntp_on
            sleep 3
            if ntp_activo; then
                aviso "Sincronizando" "Activada. Con el wifi encendido la hora real vuelve en unos segundos."
            else
                aviso "Sin exito" "Esta consola no usa timedatectl. Reinicia con el wifi encendido."
            fi
            ;;
        9|*) ExitScript ;;
    esac
done
