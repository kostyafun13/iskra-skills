#!/bin/bash
# Автозапуск Диктовки при входе в macOS: LaunchAgent, который делает open на .app.
# Повторный запуск перезаписывает агент. Убрать автозапуск: bash install_autostart.sh --udalit
set -euo pipefail

APP="${DIKTOVKA_APP_DIR:-$HOME/Applications}/Diktovka.app"
LABEL="${DIKTOVKA_BUNDLE_ID:-ru.iskra.diktovka}"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

if [ "${1:-}" = "--udalit" ]; then
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    rm -f "$PLIST"
    echo "✓ Автозапуск убран"
    exit 0
fi

if [ ! -d "$APP" ]; then
    echo "✗ Не найдено $APP — сначала bash build_app.sh"
    exit 1
fi

mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/open</string>
        <string>-a</string>
        <string>$APP</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "✓ Автозапуск настроен: $PLIST → $APP"
