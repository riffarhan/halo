#!/bin/zsh
# Removes the Halo Sync audio driver. Asks for your password.
set -euo pipefail
sudo rm -rf /Library/Audio/Plug-Ins/HAL/HaloSync.driver
sudo killall coreaudiod
echo "Removed Halo Sync."
