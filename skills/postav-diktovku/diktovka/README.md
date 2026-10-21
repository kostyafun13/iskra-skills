# Диктовка — исходники

Приложение для строки меню macOS: правый ⌘ — голос в текст, правый ⇧ — чтение выделенного вслух. Ставится скилом `postav-diktovku` — порядок, разрешения и приёмка в `../SKILL.md`.

- `Sources/Diktovka/` — исходники Swift и Objective-C.
- `helper/` — скрипты Python для локальной модели распознавания и локального голоса; без них приложение работает облаком.
- `build_app.sh` — сборка в `~/Applications/Diktovka.app`. Нужны macOS 13+ и Command Line Tools (`xcode-select --install`).
- `install_engine.sh` — по желанию: локальная модель распознавания, около 0,5 ГБ.
- `install_autostart.sh` — запуск при входе в Мак; `--udalit` убирает.

Проверка установки без меню: `~/Applications/Diktovka.app/Contents/MacOS/Diktovka --proverka`.
