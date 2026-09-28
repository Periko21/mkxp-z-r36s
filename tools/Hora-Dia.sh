#!/bin/bash
# Pone el reloj de la consola a las 12:00 y sale. Sin menus ni dependencias:
# esto funciona aunque no haya 'dialog' ni gptokeyb instalados.
[ "$(id -u)" -ne 0 ] && exec sudo -- "$0" "$@"
TTY=/dev/tty1; [ -w "$TTY" ] || TTY=/dev/console
# El sincronizado automatico devolveria la hora real en segundos si hay wifi.
command -v timedatectl >/dev/null 2>&1 && timedatectl set-ntp false >/dev/null 2>&1
date +%T -s "12:00:00" >/dev/null 2>&1
sync
printf "\033c\nHora puesta a %s -- en el juego sera de DIA.\n" "$(date +%H:%M)" > "$TTY"
sleep 3
