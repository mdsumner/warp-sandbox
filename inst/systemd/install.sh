#!/usr/bin/env bash
# Install the warp sandbox as a systemd user service and start it.
#   bash "$(Rscript -e 'cat(system.file("systemd", package = "warpsandbox"))')"/install.sh [port]
# Lingering (so it runs without a login session) needs root, once:
#   sudo loginctl enable-linger "$USER"
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
port=${1:-8090}
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}

if [ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null)" != "yes" ]; then
  echo "Lingering is off for $USER, so the service would stop at logout (or not start at all"
  echo "without a login session). As a user with sudo:  sudo loginctl enable-linger $USER"
  exit 1
fi

mkdir -p ~/.config/systemd/user
sed "s/^Environment=WARP_SANDBOX_PORT=.*/Environment=WARP_SANDBOX_PORT=$port/" \
  "$here/warp-sandbox.service" > ~/.config/systemd/user/warp-sandbox.service
systemctl --user daemon-reload
systemctl --user enable --now warp-sandbox
for i in $(seq 1 30); do
  curl -sf "http://127.0.0.1:$port/health" > /dev/null && break
  sleep 1
done
systemctl --user --no-pager status warp-sandbox | head -5
curl -sf "http://127.0.0.1:$port/health" && echo || { echo "not answering on $port yet: journalctl --user -u warp-sandbox"; exit 1; }
