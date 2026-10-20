#!/bin/sh
# Install the backend as a systemd --user service. No root needed.
#   PYTHON=/path/to/venv/bin/python ./install.sh      (needs openvino_genai)
set -e
BACKEND=$(cd "$(dirname "$0")" && pwd)
PYTHON=${PYTHON:-$HOME/ai/npu/.venv/bin/python}
"$PYTHON" -c "import openvino_genai" || { echo "openvino_genai not importable from $PYTHON" >&2; exit 1; }
UNIT_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user
mkdir -p "$UNIT_DIR"
sed -e "s|@BACKEND@|$BACKEND|" -e "s|@PYTHON@|$PYTHON|" "$BACKEND/npu-assistant.service.in" > "$UNIT_DIR/npu-assistant.service"
mkdir -p "$HOME/.local/bin"
ln -sf "$BACKEND/npu-ask" "$HOME/.local/bin/npu-ask"
systemctl --user daemon-reload
systemctl --user enable --now npu-assistant.service
systemctl --user restart npu-assistant.service
echo "npu-assistant: http://127.0.0.1:8737  (journalctl --user -u npu-assistant -f)"
