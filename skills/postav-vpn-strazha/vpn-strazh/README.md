# VPN-страж — исходники

Значок в строке меню macOS. Если охраняемое приложение открыто без нужного VPN — экран поверх всех окон и отсчёт до закрытия приложения. Ставится скилом `postav-vpn-strazha`.

- `vpn_strazh.m` — исходник на Objective-C, один файл, без зависимостей. В сеть не ходит.
- `nastroyka.primer.txt` — образец настройки.
- `ustanovit.sh` — сборка и автозапуск; `--udalit` убирает всё. Нужны Command Line Tools (`xcode-select --install`).

После установки:
- программа и настройка — `~/Library/Application Support/vpn-strazh/`;
- лог — `~/Library/Logs/vpn-strazh.log`;
- автозапуск — `~/Library/LaunchAgents/ru.iskra.vpn-strazh.plist`.

Проверка без экрана: `~/Library/Application\ Support/vpn-strazh/vpn-strazh --status`.
