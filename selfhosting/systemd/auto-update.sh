#!/bin/bash

LOGFILE="/home/$USER/.auto-update.log"

mkdir -p "$(dirname "$LOGFILE")" # updater
{
    echo "===== Auto-update started: $(date) ====="

    apt update -y 2>&1
    apt upgrade -y 2>&1
    apt autoremove -y 2>&1

    echo "===== Update complete: $(date) ====="
} > "$LOGFILE" 2>&1

if [ -f /var/run/reboot-required ]; then # notifier
    echo "Reboot required, sending notification..." >> "$LOGFILE"
    REAL_USER=$(loginctl list-sessions --no-legend | awk '{print $3}' | head -1)
    USER_ID=$(id -u "$REAL_USER")
    DBUS_ADDR="unix:path=/run/user/${USER_ID}/bus"

    sudo -u "$REAL_USER" DBUS_SESSION_BUS_ADDRESS="$DBUS_ADDR" \
        notify-send "System Update" "Updates installed. A reboot is required." \
        --icon=system-reboot --urgency=normal
fi
