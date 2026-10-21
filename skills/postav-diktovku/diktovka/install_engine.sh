#!/bin/bash
# ПО ЖЕЛАНИЮ: локальный движок распознавания «Диктовки» — venv + onnx-asr (без PyTorch)
# + модель GigaAM v3 int8 (~225 МБ). С ключом Яндекса Диктовка работает и без него (облаком);
# с ним короткие диктовки распознаются бесплатно на Маке, а облако подхватывает затор.
# Нужен python3 ≥3.10. Интернет нужен только этому скрипту; дальше движок работает офлайн.
# После установки — меню значка → «🔄 Перезапустить Диктовку», режим «Гибрид» в «Распознавание».
set -euo pipefail

APP_SUP="$HOME/Library/Application Support/Diktovka"
MODEL="${DIKTOVKA_MODEL:-gigaam-v3-e2e-ctc}"
QUANT="${DIKTOVKA_QUANT:-int8}"

# питон ≥3.10 ищем сами (onnx-asr требует 3.10+; системный /usr/bin/python3 = 3.9)
pick_python() {
    local p v
    for p in "${DIKTOVKA_PYTHON:-}" /usr/local/bin/python3 /opt/homebrew/bin/python3 \
             /usr/bin/python3 "$(command -v python3 2>/dev/null || true)"; do
        [ -n "$p" ] && [ -x "$p" ] || continue
        v=$("$p" -c 'import sys; print(sys.version_info[0]*100+sys.version_info[1])' 2>/dev/null) || continue
        [ "$v" -ge 310 ] || continue
        echo "$p"
        return 0
    done
    return 1
}
PY=$(pick_python) || { echo "✗ Нужен python3 ≥3.10 (например: brew install python)"; exit 1; }

echo "→ Python: $PY ($($PY -c 'import sys, platform; print(sys.version.split()[0], platform.machine())'))"
mkdir -p "$APP_SUP"

if [ ! -x "$APP_SUP/venv/bin/python3" ]; then
    echo "→ Создаю venv…"
    "$PY" -m venv "$APP_SUP/venv"
fi

echo "→ Ставлю onnx-asr (onnxruntime + numpy, БЕЗ torch)…"
"$APP_SUP/venv/bin/pip" install -q -U pip
"$APP_SUP/venv/bin/pip" install -q -U "onnx-asr[cpu,hub]"

echo "→ Скачиваю модель $MODEL ($QUANT)…"
HF_HOME="$APP_SUP/hf-cache" "$APP_SUP/venv/bin/python3" - "$MODEL" "$QUANT" <<'PYEOF'
import sys
import onnx_asr

model, quant = sys.argv[1], sys.argv[2]
kwargs = {"quantization": quant} if quant and quant != "none" else {}
onnx_asr.load_model(model, **kwargs)
print(f"   модель на месте: {model} ({quant})")
PYEOF

echo "✓ Движок установлен: $APP_SUP"
