#!/usr/bin/env bash
# install.sh — install daily-digest to ~/bin and scaffold the config file.
# Does not touch crontab; see README for the cron entry.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_TARGET="${HOME}/bin/daily-digest"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/daily-digest"
CONFIG_FILE="$CONFIG_DIR/config.env"
EXAMPLE="$SCRIPT_DIR/config.env.example"

mkdir -p "$HOME/bin" "$CONFIG_DIR"

MODE="${1:-symlink}"
case "$MODE" in
    symlink)
        ln -sf "$SCRIPT_DIR/bin/daily-digest" "$BIN_TARGET"
        echo "Symlinked $BIN_TARGET -> $SCRIPT_DIR/bin/daily-digest"
        ;;
    copy)
        cp "$SCRIPT_DIR/bin/daily-digest" "$BIN_TARGET"
        chmod +x "$BIN_TARGET"
        echo "Copied script to $BIN_TARGET"
        ;;
    *)
        echo "usage: install.sh [symlink|copy]" >&2
        exit 2
        ;;
esac

if [[ -f "$CONFIG_FILE" ]]; then
    echo "Config already exists at $CONFIG_FILE; leaving it alone."
else
    cp "$EXAMPLE" "$CONFIG_FILE"
    echo "Wrote starter config to $CONFIG_FILE — edit before first run."
fi

cat <<EOF

Next steps:
  1. Edit $CONFIG_FILE
  2. Run once to verify: $BIN_TARGET
  3. Add to crontab for daily 5am run:
       0 5 * * * $BIN_TARGET >> \$HOME/.local/share/daily-digest.log 2>&1
EOF
