#!/bin/bash
# VPN-страж на этот Мак: сборка, настройка, автозапуск при входе, перезапуск при сбое.
# Повторный запуск обновляет программу и не трогает настройку.
#   bash ustanovit.sh            — поставить или обновить
#   bash ustanovit.sh --udalit   — убрать совсем: автозапуск, программу, настройку, лог
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DIR="$HOME/Library/Application Support/vpn-strazh"
BIN="$DIR/vpn-strazh"
LOG="$HOME/Library/Logs/vpn-strazh.log"
LABEL="ru.iskra.vpn-strazh"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

if [ "${1:-}" = "--udalit" ]; then
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    rm -f "$PLIST" "$LOG"
    rm -rf "$DIR"
    echo "✓ VPN-страж удалён"
    exit 0
fi

if ! xcode-select -p >/dev/null 2>&1; then
    echo "✗ Нет Command Line Tools. Поставь: xcode-select --install"
    exit 1
fi

mkdir -p "$DIR" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
clang -fobjc-arc -O2 -framework Cocoa -o "$BIN" "$HERE/vpn_strazh.m"
[ -f "$DIR/nastroyka.txt" ] || cp "$HERE/nastroyka.primer.txt" "$DIR/nastroyka.txt"

# Без нужного VPN страж сразу закрыл бы приложение, из которого идёт установка.
STATUS="$("$BIN" --status)"
case "$STATUS" in
    *overlay=SHOW*)
        echo "✗ Сейчас приложение открыто без нужного VPN: $STATUS"
        echo "  Включи VPN и запусти установку ещё раз."
        exit 1
        ;;
esac

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BIN</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>StandardOutPath</key>
    <string>$LOG</string>
    <key>StandardErrorPath</key>
    <string>$LOG</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
# bootout завершается не сразу: повторяем, пока launchd не отпустит старый процесс.
for _ in 1 2 3 4 5 6 7 8 9 10; do
    launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null && break
    sleep 1
done
sleep 2
if ! launchctl list | grep -q "$LABEL"; then
    echo "✗ VPN-страж не запустился. Лог: $LOG"
    exit 1
fi
echo "✓ VPN-страж запущен: $("$BIN" --status)"
echo "  Значок 🛡 в строке меню. Лог: $LOG"
