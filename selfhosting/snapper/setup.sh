#!/bin/bash
# automated snapper setup for selfhosting
if ! command -v snapper &> /dev/null; then
    echo "snapper is not installed. Please install it first."
    exit 1
fi
read -p "Enter path (e.g., /mnt/cloud/portainer): " path_name
parent_dir="${path_name%/*}"
if [ -z "$parent_dir" ] || [ ! -d "$parent_dir" ]; then
    echo "Error: Parent directory '$parent_dir' does not exist."
    exit 2
fi
cfg_name="${path_name##*/}"
sudo -v
btrfs subvolume create "$path_name" || { echo "Error: is $parent_dir a btrfs filesystem?."; exit 3; }
btrfs property set "$path_name" compression zstd
sudo btrfs subvolume create "$path_name/.snapshots"
cp config "$cfg_name"
sed -i "s|^SUBVOLUME=.*|SUBVOLUME=$path_name|" "$cfg_name"
sudo mv "$cfg_name" "/etc/snapper/configs/$cfg_name" || { echo "Error: failed to move configuration file to /etc/snapper/configs. Make sure the path name is not repeated."; exit 4; }
sudo sed -i "s/SNAPPER_CONFIGS=\"\(.*\)\"/SNAPPER_CONFIGS=\"\1 $cfg_name\"/" /etc/default/snapper
snapper list-configs | grep "$cfg_name" && { echo "Snapper configuration '$cfg_name' created successfully."; exit 0; } || { echo "Error: failed to add '$cfg_name' to SNAPPER_CONFIGS."; exit 5; }
if ! diff -q snapper-cleanup.timer /usr/lib/systemd/system/snapper-cleanup.timer > /dev/null 2>&1; then
    sudo cp -f snapper-cleanup.timer /usr/lib/systemd/system/
else
    echo "Snapper cleanup timer already patched."
fi
if ! diff -q snapper-timeline.timer /usr/lib/systemd/system/snapper-timeline.timer > /dev/null 2>&1; then
    sudo cp -f snapper-timeline.timer /usr/lib/systemd/system/
else
    echo "Snapper timeline timer already patched."
fi
