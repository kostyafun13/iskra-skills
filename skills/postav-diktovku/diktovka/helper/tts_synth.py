#!/usr/bin/env python3
"""Резидентный TTS-сервер vosk-tts (голос автора — спикер №2, выбор 04.08.2026).
Модель (~0.7 ГБ в памяти) грузится ОДИН раз — потому сервер, а не одноразовый
скрипт: холодный запуск ~40 с, тёплый синтез — секунды. При простое >20 минут
выходит сам, Speaker.swift перезапустит при следующем чтении.

Протокол (как у asr_server.py — построчный, через stdin/stdout):
  вход:  {"text": "...", "out": "/путь.wav", "speaker": 2}
  выход: {"ready": true} после загрузки модели;
         {"ok": true, "out": "..."} / {"error": "..."} на каждое задание."""
import json
import os
import sys
import threading
import time

try:
    import certifi  # мина Python 3.13: без явного пути к сертификатам падает докачка
    os.environ.setdefault("SSL_CERT_FILE", certifi.where())
except ImportError:
    pass

from vosk_tts import Model, Synth

MODEL_NAME = "vosk-model-tts-ru-0.9-multi"
IDLE_EXIT_SEC = 0  # 0 = не засыпать: голос всегда в памяти (правило автора 13.09.2026); было 240 * 60  # 20→90→240 мин (13.08: перерыв 2.5 ч снова разбудил запасной
                          # голос); 0.7 ГБ RAM держим рабочий день, ночью отдаём.
                          # 0 = жить вечно (если автор попросит «совсем без прогревов»)

# Модель не читает цифры (KeyError '2' — инцидент 04.08): разворачиваем числа
# в слова; при прочих непроизносимых символах — вторая попытка чистой кириллицей
import re  # noqa: E402

# Словарь модели (config.json phoneme_id_map) знает ТОЛЬКО: буквы, пробел и
# ! ' ( ) , - . : ; ?  — любое тире «–—», ёлочки, «…» роняют синтез KeyError
# (инцидент 12.08: чтение стопалось посреди текста на «–»). Приводим заранее.
_CHAR_FIXES = [
    (re.compile("[\u00a0\u2009\u202f\u200b\ufeff]"), " "),  # неразрывные/тонкие пробелы
    (re.compile(r"…"), "..."),                          # … → ...
    (re.compile(r"[«»„“”\"]"), " "),                         # кавычки не произносятся
    (re.compile(r"[’‘`´]"), "'"),
    (re.compile(r"\s*[—–−―]+\s*"), ", "),                    # тире = пауза
    (re.compile(r"[•●▪◦·]+"), "; "),                         # буллеты списков = пауза
    (re.compile(r"№"), " номер "),
    (re.compile(r"%"), " процентов "),
    (re.compile(r"\+"), " плюс "),
]
# Финальная страховка: всё вне известного модели — в пробел (латиницу оставляем,
# словарь модели её транскрибирует; за год ни одного падения на латинице)
_UNKNOWN = re.compile(r"[^А-Яа-яЁёA-Za-z0-9 !'(),.:;?-]")
_LEAD_PUNCT = re.compile(r"^[\s,;:.-]+")


def normalize(text: str) -> str:
    for rx, rep in _CHAR_FIXES:
        text = rx.sub(rep, text)
    text = _num_expand(text)
    text = _UNKNOWN.sub(" ", text)
    return _LEAD_PUNCT.sub("", text)


try:
    from num2words import num2words

    def _num_to_words(m: "re.Match") -> str:
        try:
            return " " + num2words(int(m.group(0)), lang="ru") + " "
        except Exception:
            return " "

    def _num_expand(text: str) -> str:
        return re.sub(r"\d+", _num_to_words, text)
except ImportError:
    def _num_expand(text: str) -> str:
        return text


def cyrillic_only(text: str) -> str:
    return re.sub(r"[^А-Яа-яЁё .,!?;:-]", " ", text)


# У модели лимит ~500 токенов на вход (инцидент 04.08: «512 by 668» на длинном
# выделении → чтение падало в запасной голос). Режем текст по предложениям
# на куски ≤350 символов и склеиваем wav-части в один файл.
def split_sentences(text: str, max_len: int = 350) -> list:
    parts = re.split(r"(?<=[.!?;…])\s+", text)
    chunks, cur = [], ""
    for p in parts:
        p = p.strip()
        if not p:
            continue
        while len(p) > max_len:  # предложение-монстр — режем по запятой/пробелу
            cut = p.rfind(",", 0, max_len)
            if cut < max_len // 2:
                cut = p.rfind(" ", 0, max_len)
            if cut <= 0:
                cut = max_len
            piece = (cur + " " + p[:cut]).strip() if cur else p[:cut].strip()
            chunks.append(piece)
            cur = ""
            p = p[cut:].lstrip(", ").strip()
        if cur and len(cur) + len(p) + 1 > max_len:
            chunks.append(cur)
            cur = p
        else:
            cur = (cur + " " + p).strip()
    if cur:
        chunks.append(cur)
    return chunks or [text]


def synth_one(synth: "Synth", text: str, path: str, speaker: int) -> bool:
    if not text.strip():
        return False
    try:
        synth.synth(text, path, speaker_id=speaker)
        return True
    except Exception:  # noqa: BLE001 — символы вне словаря модели
        clean = cyrillic_only(text).strip()
        if not clean:
            return False
        # кусок безнадёжен → пропускаем, конвейер живёт (инцидент 12.08:
        # исключение отсюда убивало ВСЁ чтение посреди текста)
        try:
            synth.synth(clean, path, speaker_id=speaker)
            return True
        except Exception as e:  # noqa: BLE001
            print(f"tts_synth: кусок пропущен ({e!r}): {clean[:60]}", file=sys.stderr, flush=True)
            return False


# Задания читает ОТДЕЛЬНЫЙ поток в очередь: пока синтез крутится, main видит,
# что пришло новое задание, и БРОСАЕТ недожёванное старое (инцидент 13.08:
# повторные нажатия копили очередь на минуты — «нажимаю, не воспроизводится»;
# для читалки звучать должно только ПОСЛЕДНЕЕ нажатие, остальное — мусор)
import queue  # noqa: E402

_jobs: "queue.Queue" = queue.Queue()


def _stdin_reader() -> None:
    for line in sys.stdin:
        line = line.strip()
        if line:
            _jobs.put(line)
    _jobs.put(None)  # EOF — Swift закрыл пайп, выходим


# Конвейер: каждый готовый кусок сразу уходит строкой {"part": путь} — Swift
# играет его, пока синтезится следующий (синтез ~реального времени, ждать всё
# целиком на длинном тексте = минуты тишины). Файлы кусков удаляет Swift.
def synth_stream(synth: "Synth", text: str, out_base: str, speaker: int) -> None:
    chunks = split_sentences(normalize(text))
    # первый кусок — короткий: звук стартует через ~2-4 с, остальное догоняет
    if chunks and len(chunks[0]) > 160:
        chunks = split_sentences(chunks[0], 140) + chunks[1:]
    made = 0
    for i, ch in enumerate(chunks):
        if not _jobs.empty():  # прилетела отмена/новое задание — старое никому не нужно
            print(f"tts_synth: задание брошено (готово {made}/{len(chunks)} кусков)",
                  file=sys.stderr, flush=True)
            return
        part = f"{out_base}.part{i}.wav"
        if synth_one(synth, ch, part, speaker):
            made += 1
            print(json.dumps({"part": part}), flush=True)
    if made == 0:
        raise ValueError("пустой текст после чистки")

_last_job = time.time()


def _watchdog() -> None:
    while True:
        time.sleep(60)
        if IDLE_EXIT_SEC and time.time() - _last_job > IDLE_EXIT_SEC:
            os._exit(0)


def main() -> int:
    global _last_job
    model = Model(model_name=MODEL_NAME)
    synth = Synth(model)
    threading.Thread(target=_watchdog, daemon=True).start()
    threading.Thread(target=_stdin_reader, daemon=True).start()
    print(json.dumps({"ready": True}), flush=True)
    while True:
        line = _jobs.get()
        if line is None:
            break
        _last_job = time.time()
        try:
            job = json.loads(line)
        except Exception as e:  # noqa: BLE001
            print(json.dumps({"error": str(e)}), flush=True)
            continue
        if job.get("cancel"):
            continue  # отмена без задания: текущий синтез уже брошен в synth_stream, молчим
        try:
            synth_stream(synth, job["text"], job["out"], int(job.get("speaker", 2)))
            print(json.dumps({"done": True}), flush=True)
        except Exception as e:  # noqa: BLE001 — любой сбой уходит строкой, сервер живёт
            print(json.dumps({"error": str(e)}), flush=True)
        _last_job = time.time()
    return 0


if __name__ == "__main__":
    sys.exit(main())
