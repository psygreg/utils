#!/bin/bash
if ! which flatpak > /dev/null; then
    echo "This script is only for systems with the flatpak package manager."
    exit 1
fi
read -p "This will install the systemd service for automatic updates (flatpak). Proceed? (Y/N)" decision
case "$decision" in
    [Yy]* )
        sudo cp flatpak-update.service /etc/systemd/system/
        sudo cp flatpak-update.timer /etc/systemd/system/
        sudo systemctl enable --now flatpak-update.timer
        echo "Flatpak auto-update service installed and enabled."
        exit 0
        ;;
    * )
        echo "Aborting setup."
        exit 100
        ;;
esac
