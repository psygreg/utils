#!/bin/bash
if ! which apt > /dev/null; then
    echo "This script is only for Debian and Ubuntu-based systems with the apt package manager."
    exit 1
fi
read -p "This will install the systemd service for automatic updates (apt). Proceed? (Y/N)" decision
case "$decision" in
    [Yy]* )
        echo "Setting up auto-update service..."
        sudo cp auto-update.service /etc/systemd/system/
        sudo cp auto-update.timer /etc/systemd/system/
        chmod +x auto-update.sh # ensure it's executable
        sudo cp auto-update.sh /usr/local/bin/
        sudo systemctl daemon-reload
        sudo systemctl enable --now auto-update.timer
        echo "Auto-update service installed and enabled."
        exit 0
        ;;
    * )
        echo "Aborting setup."
        exit 100
        ;;
esac
