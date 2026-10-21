#!/bin/bash
# Сборка Diktovka.app из исходников на твоём Маке. Xcode не нужен — хватает Command Line Tools.
#   Приложение:          ~/Applications/Diktovka.app   (другая папка — DIKTOVKA_APP_DIR)
#   Промежуточные файлы: ~/Library/Caches/Diktovka-build (другая папка — DIKTOVKA_BUILD_DIR)
#   Подпись: сертификат DIKTOVKA_SIGN_ID («Diktovka Local»), если он есть в связке ключей;
#            нет — ad-hoc (после каждой пересборки Универсальный доступ выдаётся заново).
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="${DIKTOVKA_APP_DIR:-$HOME/Applications}"
BUILD="${DIKTOVKA_BUILD_DIR:-$HOME/Library/Caches/Diktovka-build}"
BUNDLE_ID="${DIKTOVKA_BUNDLE_ID:-ru.iskra.diktovka}"
IDENT="${DIKTOVKA_SIGN_ID:-Diktovka Local}"

# ── что нужно до сборки
MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
if [ "$MAJOR" -lt 13 ]; then
    echo "✗ Нужна macOS 13 или новее, у тебя $(sw_vers -productVersion)."
    exit 1
fi
if ! xcode-select -p >/dev/null 2>&1 || ! xcrun --find swiftc >/dev/null 2>&1; then
    echo "✗ Нет Command Line Tools. Выполни: xcode-select --install"
    echo "  В окне нажми «Установить», дождись конца и запусти сборку снова."
    exit 1
fi

mkdir -p "$BUILD" "$APP_DIR"
ARCH="$(uname -m)"
echo "→ Собираю Диктовку ($ARCH) из $SRC"

# Прежняя сборка подписана сертификатом, а его сейчас нет в связке — не понижаем подпись
# до ad-hoc молча: macOS забудет выданный Универсальный доступ.
if [ -d "$APP_DIR/Diktovka.app" ]; then
    AUTH="$( (codesign -dv --verbose=2 "$APP_DIR/Diktovka.app" 2>&1 || true) | awk -F= '/^Authority=/{print $2; exit}')"
    if [ -n "$AUTH" ] && ! security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$AUTH\""; then
        echo "⛔️ Прежняя сборка подписана «$AUTH», а сертификата сейчас нет — сборка остановлена."
        exit 1
    fi
fi

# VFS-оверлей нужен ТОЛЬКО полуобновлённым Command Line Tools: там лежат И старый
# module.modulemap, И новый bridging.modulemap, оба объявляют SwiftBridging →
# «redefinition of module». Прячем старый от компилятора, не трогая системные файлы.
SWIFT_INC="/Library/Developer/CommandLineTools/usr/include/swift"
OVERLAY=""
if [ -f "$SWIFT_INC/module.modulemap" ] && [ -f "$SWIFT_INC/bridging.modulemap" ]; then
    printf '// пустышка: прячем дубль SwiftBridging из полуобновлённых CLT\n' > "$BUILD/empty.modulemap"
    cat > "$BUILD/vfs-overlay.yaml" <<EOF
{
  "version": 0,
  "case-sensitive": "false",
  "roots": [
    {
      "name": "$SWIFT_INC",
      "type": "directory",
      "contents": [
        { "name": "module.modulemap", "type": "file", "external-contents": "$BUILD/empty.modulemap" }
      ]
    }
  ]
}
EOF
    OVERLAY="$BUILD/vfs-overlay.yaml"
    echo "  (полуобновлённые Command Line Tools — применяю VFS-оверлей)"
fi

# nice 19: компилятор не отнимает процессор у работающей Диктовки и остального Мака.
# ObjCTry.m ловит NSException от AVAudioEngine, Bluetooth.m — тумблер Bluetooth (кнопка Б).
nice -n 19 clang -c -O2 -target "$ARCH-apple-macos13.0" \
    "$SRC/Sources/Diktovka/ObjCTry.m" -o "$BUILD/ObjCTry.o"
nice -n 19 clang -c -O2 -target "$ARCH-apple-macos13.0" \
    "$SRC/Sources/Diktovka/Bluetooth.m" -o "$BUILD/Bluetooth.o"
echo "→ swiftc -O (минута-две)…"
nice -n 19 swiftc -O -swift-version 5 -target "$ARCH-apple-macos13.0" \
    ${OVERLAY:+-vfsoverlay "$OVERLAY"} \
    -import-objc-header "$SRC/Sources/Diktovka/ObjCTry.h" \
    -framework IOBluetooth \
    "$SRC"/Sources/Diktovka/*.swift "$BUILD/ObjCTry.o" "$BUILD/Bluetooth.o" -o "$BUILD/Diktovka-bin"

# Бандл под ЖИВЫМ процессом не трогаем: macOS привязывает доверие к подписи на диске.
# Приложение запущено → кладём сборку рядом, подменится при «🔄 Перезапустить Диктовку».
APP="$APP_DIR/Diktovka.app"
STAGED=""
PROCESS_STATUS=0
pgrep -qf "$APP_DIR/Diktovka.app/Contents/MacOS/Diktovka" || PROCESS_STATUS=$?
if [ "$PROCESS_STATUS" -ne 1 ]; then
    APP="$APP_DIR/Diktovka.new.app"
    STAGED=1
    echo "  ⚠️ Диктовка запущена — собираю в $APP (подменится при перезапуске из меню)"
fi
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/helper"
cp "$BUILD/Diktovka-bin" "$APP/Contents/MacOS/Diktovka"
cp "$SRC"/helper/*.py "$APP/Contents/Resources/helper/"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>Diktovka</string>
    <key>CFBundleDisplayName</key>
    <string>Диктовка</string>
    <key>CFBundleExecutable</key>
    <string>Diktovka</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Диктовка записывает голос, чтобы превратить его в текст: на этом Маке или в Яндекс SpeechKit по твоему ключу.</string>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>Кнопка Б включает и выключает Bluetooth, чтобы переключаться между наушниками и встроенным микрофоном.</string>
</dict>
</plist>
EOF

# Файлы из ZIP с GitHub несут карантинную метку — внутри бандла она мешает подписи и запуску
xattr -cr "$APP" 2>/dev/null || true

# Подпись: сначала бинарь, потом бандл (подпись бандла поверх ad-hoc-подписи линковщика
# падала с errSecInternalComponent). Вложенных бандлов нет — --deep не нужен.
if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$IDENT\""; then
    if codesign --force --sign "$IDENT" "$APP/Contents/MacOS/Diktovka" \
       && codesign --force --sign "$IDENT" "$APP" \
       && [[ "$(codesign -dv --verbose=2 "$APP" 2>&1)" == *"Authority=$IDENT"* ]]; then
        echo "  подпись: $IDENT (Универсальный доступ переживёт пересборки)"
    else
        rm -rf "$APP"
        echo "  ⛔️ подпись сертификатом «$IDENT» не прошла — сборка удалена. Повторить: bash build_app.sh"
        exit 1
    fi
else
    codesign --force --sign - "$APP/Contents/MacOS/Diktovka"
    codesign --force --sign - "$APP"
    echo "  подпись: ad-hoc. После КАЖДОЙ пересборки Универсальный доступ выдаётся заново:"
    echo "  Настройки → Конфиденциальность и безопасность → Универсальный доступ → Diktovka «−», затем «+»."
fi
codesign --verify --strict "$APP"
echo "✓ Готово: $APP"
if [ -n "$STAGED" ]; then
    echo "  Работающая Диктовка не тронута. Меню значка → «🔄 Перезапустить Диктовку» подменит сборку."
else
    echo "  Запуск: open \"$APP\""
fi
