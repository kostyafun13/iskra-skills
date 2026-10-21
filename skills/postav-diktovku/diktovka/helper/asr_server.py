#!/usr/bin/env python3
"""Движок «Диктовки»: GigaAM v3 (ONNX, int8) поверх onnx-asr — всё локально, без сети.

Протокол (JSON-строки):
  stdin  → {"id": 1, "wav": "/путь/кусок.wav", "keep": false}
  stdout ← {"event": "loading"} / {"event": "ready"} / {"id": 1, "text": "…", "sec": 0.8}
"""
import json
import os
import sys
import time


def emit(obj):
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
    sys.stdout.flush()


MODEL = os.environ.get("DIKTOVKA_MODEL", "gigaam-v3-e2e-ctc")
QUANT = os.environ.get("DIKTOVKA_QUANT", "int8")

emit({"event": "loading", "model": MODEL, "quant": QUANT})
try:
    import onnx_asr

    kwargs = {}
    if QUANT and QUANT != "none":
        kwargs["quantization"] = QUANT
    model = onnx_asr.load_model(MODEL, **kwargs)
except Exception as e:  # noqa: BLE001 — любую причину показываем в меню
    emit({"event": "fatal", "error": f"{type(e).__name__}: {e}"})
    sys.exit(1)
emit({"event": "ready", "model": MODEL})

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        req = json.loads(line)
    except json.JSONDecodeError:
        continue
    if req.get("cmd") == "quit":
        break
    rid = req.get("id")
    wav = req.get("wav", "")
    try:
        t0 = time.time()
        text = model.recognize(wav)
        if not isinstance(text, str):
            text = getattr(text, "text", str(text))
        emit({"id": rid, "text": text, "sec": round(time.time() - t0, 2)})
    except Exception as e:  # noqa: BLE001
        emit({"id": rid, "text": "", "error": f"{type(e).__name__}: {e}"})
    finally:
        if not req.get("keep"):
            try:
                os.remove(wav)
            except OSError:
                pass
