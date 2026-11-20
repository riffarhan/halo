#!/bin/zsh
# Installs (or updates) the Halo Sync audio driver and restarts Core Audio. Asks for your password.
# Sound stops for a second while Core Audio restarts.
set -euo pipefail
cd "$(dirname "$0")"
./build-driver.sh
SRC="$HOME/Library/Caches/Halo-build/HaloSync.driver"
sudo rm -rf /Library/Audio/Plug-Ins/HAL/HaloSync.driver
sudo cp -R "$SRC" /Library/Audio/Plug-Ins/HAL/
sudo chown -R root:wheel /Library/Audio/Plug-Ins/HAL/HaloSync.driver
sudo killall coreaudiod
echo "Installed. 'Halo Sync' should appear in Sound settings in a few seconds."
