#!/bin/bash
# Installs the built driver for all users and restarts the audio server (sound drops for about a second).
set -euo pipefail
cd "$(dirname "$0")"
DEST=/Library/Audio/Plug-Ins/HAL/ThunderControlAudio.driver
/usr/bin/osascript -e "do shell script \"/bin/rm -rf '$DEST' && /usr/bin/ditto '$PWD/ThunderControlAudio.driver' '$DEST' && /usr/sbin/chown -R root:wheel '$DEST' && /usr/bin/killall coreaudiod\" with administrator privileges with prompt \"ThunderControl 오디오 장치를 설치합니다.\""
