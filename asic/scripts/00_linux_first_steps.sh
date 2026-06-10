#!/usr/bin/env bash
set -euo pipefail
cat <<'MSG'
Linux essentials for this project:
  pwd                         show current folder
  ls                          list files
  cd folder_name              enter folder
  cd ..                       go back one folder
  mkdir -p folder_name        create folder
  unzip file.zip              extract zip
  nano file                   simple text editor, Ctrl+O save, Ctrl+X exit
  clear                       clear terminal

Recommended workflow:
  mkdir -p ~/evpix_asic
  unzip evpix_asic_openroad_kit_v1.zip -d ~/evpix_asic
  cd ~/evpix_asic/evpix_asic_openroad_kit_v1
  bash scripts/01_check_tools.sh
MSG
