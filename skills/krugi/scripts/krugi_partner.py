"""Лист партнёра: партнёр пишет ники и статусы людей, которых зовёт он, — владелец видит копию у себя.

Свои контакты владелец партнёру не отдаёт: в лист партнёра идут только люди, которых зовёт не владелец.
У каждой колонки один хозяин, поэтому затирания нет:
  A–D и I — пишет скрипт: круг, имя, компания, кто зовёт, ключ (защищены от правки);
  E–H — пишет партнёр: Telegram @ник, статус, дата, заметка. Новых людей партнёр добавляет строкой внизу без ключа.
Человек ушёл из кругов, а партнёр по нему писал — строка остаётся с пометкой «вне кругов сейчас».
Копия владельцу — полный лист партнёра плюс колонка «Фото в деке». Перезаписывается при каждом запуске.

Таблицы создаёт сам скрипт (команда sozdat): подключение Google из скила podklyuchit-google правит только
файлы, которые создало само. Доступ партнёру даёт владелец: Настройки доступа → почта партнёра → Редактор.

Запуск из папки скрипта интерпретатором подключения Google:
  ../google/.venv/bin/python krugi_partner.py sozdat
  ../google/.venv/bin/python krugi_partner.py obnovit --papka private/<партия>
Итог obnovit: dannye/niki_ot_partnera.json (ключ → ник) для фото и плана.
"""
import argparse
import importlib.util
import json
import os
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent
GOOGLE = Path(os.environ.get("GOOGLE_DIR", ROOT.parent / "google"))
TABLICY = ROOT / "private" / "tablicy.json"
NASTROYKA = ROOT / "private" / "nastroyka.json"
LIST_PARTNERA, LIST_VLADELCA = "Люди кругов", "Круги — люди от партнёра"
SHAPKA = ["Круг", "Имя", "Компания", "Кто зовёт", "Telegram @ник (пишет партнёр)", "Статус (пишет партнёр)",
          "Дата (пишет партнёр)", "Заметка (пишет партнёр)", "Ключ (служебное)"]
STATUSY = ["позвал", "согласился", "отказался", "круг прошёл", "новый — добавил партнёр"]
SHIRINA = 9


def chitat(f, d):
    f = Path(f)
    return json.loads(f.read_text(encoding="utf-8")) if f.exists() else d


def zagruzit(imya, papka):
    spec = importlib.util.spec_from_file_location(imya, Path(papka) / f"{imya}.py")
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def lyudi_partnera(papka, vladelec, partner=""):
    """[тема, имя, компания, кто зовёт, ключ] — только те, кого явно зовёт партнёр. Пробные круги — с пометкой.
    Кто зовёт не указан — строку не отдаём: это может быть контакт владельца. Один ключ — одна строка."""
    plan = zagruzit("krugi_plan", ROOT)
    d = Path(papka) / "dannye"
    vse = []
    for fayl in ("krugi.json", "krugi_proby.json"):
        for k in chitat(d / fayl, []):
            vse.append(dict(k, probnyy=k.get("probnyy") or fayl == "krugi_proby.json"))
    out, uzhe = [], {}
    for k in vse:
        f = d / f"krug_{k['n']}.json"
        lyudi = chitat(f, {}).get("lyudi") or k.get("lyudi", [])
        zovut = {p["k"]: p.get("zovet", "") for p in k.get("lyudi", [])}
        for p in lyudi:
            z = p.get("zovet") or zovut.get(p["k"], "")
            if plan.kto_zovet(z, vladelec, partner) != "partner":
                continue
            tema = k["tema"] + (" (пробный)" if k.get("probnyy") else "")
            if p["k"] in uzhe:
                print(f"Внимание: {p['imya']} стоит в двух кругах — «{uzhe[p['k']]}» и «{tema}». В листе — первый.")
                continue
            uzhe[p["k"]] = tema
            out.append([tema, p["imya"], p.get("komp", ""), z, p["k"]])
    return out


def sliyanie(staroe, nashi, podskazki=None):
    """Чистая логика листа. staroe — строки листа без шапки; nashi — из lyudi_partnera;
    podskazki — ключ → «@ник (откуда)» для пустых ячеек ника. Колонки партнёра E–H не затираются никогда.
    Порядок строк держится: старые на своих местах, новые люди — внизу. Иначе ввод партнёра в открытом листе
    попадёт к другому человеку."""
    podskazki = podskazki or {}
    nashi_po_k = {x[4]: x for x in nashi}
    itog, byli = [], set()
    for r in staroe:
        r = (list(r) + [""] * SHIRINA)[:SHIRINA]
        k = r[8]
        if not k:
            if any(str(c).strip() for c in r[:8]):
                itog.append(r)  # человек, которого добавил партнёр
            continue
        if k in byli:
            continue
        byli.add(k)
        if k in nashi_po_k:
            tema, imya, komp, zovet, _ = nashi_po_k[k]
            nik = r[4] if str(r[4]).strip() else podskazki.get(k, "")
            itog.append([tema, imya, komp, zovet, nik] + r[5:8] + [k])
        elif any(str(c).strip() for c in r[4:8]):
            itog.append(r[:3] + ["вне кругов сейчас"] + r[4:])
    for tema, imya, komp, zovet, k in nashi:
        if k not in byli:
            itog.append([tema, imya, komp, zovet, podskazki.get(k, ""), "", "", "", k])
    return itog


def bezopasno(v):
    """Свои ячейки — как текст: имя или компания с «=», «+», «-» не станет формулой."""
    return "'" + v if isinstance(v, str) and v[:1] in "=+-" else v


def podskazki_nikov(papka):
    d = Path(papka) / "dannye"
    out = {k: f"@{v['nik']} (по телефону)" for k, v in chitat(d / "niki_po_telefonu.json", {}).items()
           if isinstance(v, dict) and v.get("nik")}
    for fayl in ("krugi.json", "krugi_proby.json"):
        for k in chitat(d / fayl, []):
            for p in k.get("lyudi", []):
                if p.get("nik"):
                    out.setdefault(p["k"], f"@{p['nik'].lstrip('@')} (из чата)")
    return out


# ---------- Google ----------

def google():
    if not (GOOGLE / "google_app.py").exists():
        raise SystemExit(f"Нет {GOOGLE / 'google_app.py'}. Сначала скил podklyuchit-google (или GOOGLE_DIR).")
    ga = zagruzit("google_app", GOOGLE)
    creds = ga.credentials()
    return ga.service(creds, "sheets", "v4"), ga.service(creds, "drive", "v3")


def sozdat_tablicu(dr, nazvanie):
    f = dr.files().create(body={"name": nazvanie, "mimeType": "application/vnd.google-apps.spreadsheet"},
                          fields="id,webViewLink").execute()
    return f["id"], f["webViewLink"]


def list_id(sh, sid, title):
    meta = sh.spreadsheets().get(spreadsheetId=sid, fields="sheets.properties(sheetId,title)").execute()
    ids = {s["properties"]["title"]: s["properties"]["sheetId"] for s in meta["sheets"]}
    if title in ids:
        return ids[title], False
    r = sh.spreadsheets().batchUpdate(spreadsheetId=sid, body={"requests": [{"addSheet": {"properties": {
        "title": title, "gridProperties": {"frozenRowCount": 1}}}}]}).execute()
    return r["replies"][0]["addSheet"]["properties"]["sheetId"], True


def oformit(sh, sid, gid, zashchita, moya_pochta=""):
    shirina = [260, 200, 240, 170, 220, 170, 120, 300, 130, 110]
    reqs = [{"repeatCell": {"range": {"sheetId": gid}, "cell": {"userEnteredFormat": {"wrapStrategy": "WRAP", "verticalAlignment": "TOP"}},
                            "fields": "userEnteredFormat(wrapStrategy,verticalAlignment)"}},
            {"repeatCell": {"range": {"sheetId": gid, "startRowIndex": 0, "endRowIndex": 1},
                            "cell": {"userEnteredFormat": {"textFormat": {"bold": True}}}, "fields": "userEnteredFormat.textFormat.bold"}}]
    reqs += [{"updateDimensionProperties": {"range": {"sheetId": gid, "dimension": "COLUMNS", "startIndex": j, "endIndex": j + 1},
                                            "properties": {"pixelSize": px}, "fields": "pixelSize"}} for j, px in enumerate(shirina)]
    if zashchita:  # партнёр пишет только E–H; A–D, I и шапку правит только владелец
        reqs.append({"setDataValidation": {"range": {"sheetId": gid, "startRowIndex": 1, "startColumnIndex": 5, "endColumnIndex": 6},
                     "rule": {"condition": {"type": "ONE_OF_LIST", "values": [{"userEnteredValue": s} for s in STATUSY]},
                              "strict": False, "showCustomUi": True}}})
        redaktory = {"users": [moya_pochta]} if moya_pochta else {}
        # A–D — с предупреждением: строку нового человека партнёр заполняет сам. Ключ I — только скрипт.
        reqs.append({"addProtectedRange": {"protectedRange": {"range": {"sheetId": gid, "startRowIndex": 0, "startColumnIndex": 0,
                     "endColumnIndex": 4}, "description": "Заполняет скрипт; новых людей пиши строкой внизу", "warningOnly": True}}})
        reqs.append({"addProtectedRange": {"protectedRange": {"range": {"sheetId": gid, "startRowIndex": 0, "startColumnIndex": 8,
                     "endColumnIndex": 9}, "description": "Ключ — заполняет скрипт", "warningOnly": False, "editors": redaktory}}})
        reqs.append({"addProtectedRange": {"protectedRange": {"range": {"sheetId": gid, "startRowIndex": 0, "endRowIndex": 1},
                     "description": "Шапка", "warningOnly": False, "editors": redaktory}}})
    sh.spreadsheets().batchUpdate(spreadsheetId=sid, body={"requests": reqs}).execute()


def zapisat_list(sh, sid, title, stroki, bylo_strok=0):
    """Сначала запись поверх, потом чистка хвоста. Без «очистить, потом записать»: упадёт запись — лист не пустой."""
    shir = max(len(r) for r in stroki)
    stroki = [list(r) + [""] * (shir - len(r)) for r in stroki]
    sh.spreadsheets().values().update(spreadsheetId=sid, range=f"'{title}'!A1", valueInputOption="USER_ENTERED",
                                      body={"values": stroki}).execute()
    if bylo_strok > len(stroki):
        sh.spreadsheets().values().clear(spreadsheetId=sid, range=f"'{title}'!A{len(stroki) + 1}:Z{bylo_strok}").execute()


def sozdat():
    t = chitat(TABLICY, {})
    if t.get("partner") and t.get("vladelec"):
        raise SystemExit(f"Таблицы уже созданы: {TABLICY}. Повторно не создаю.")
    sh, dr = google()
    pochta = dr.about().get(fields="user(emailAddress)").execute()["user"]["emailAddress"]
    t["partner"], ssylka_p = sozdat_tablicu(dr, "Круги — люди для партнёра")
    t["vladelec"], ssylka_v = sozdat_tablicu(dr, "Круги — люди от партнёра (владелец)")
    gid, _ = list_id(sh, t["partner"], LIST_PARTNERA)
    oformit(sh, t["partner"], gid, zashchita=True, moya_pochta=pochta)
    zapisat_list(sh, t["partner"], LIST_PARTNERA, [SHAPKA])
    kgid, _ = list_id(sh, t["vladelec"], LIST_VLADELCA)
    oformit(sh, t["vladelec"], kgid, zashchita=False)
    TABLICY.parent.mkdir(exist_ok=True)
    TABLICY.write_text(json.dumps(t, ensure_ascii=False, indent=1), encoding="utf-8")
    print("Таблица партнёра:", ssylka_p)
    print("Копия владельца:", ssylka_v)
    print("Дальше владелец сам даёт партнёру доступ «Редактор» к первой таблице. Ссылку в nastroyka.json → partner.ssylka.")


def obnovit(papka):
    t = chitat(TABLICY, {})
    if not t.get("partner"):
        raise SystemExit("Таблиц нет: сначала sozdat.")
    nastr = chitat(NASTROYKA, {})
    sh, _ = google()
    # FORMULA: формулы, ссылки и даты партнёра возвращаются как были, а не видимым текстом
    staroe = sh.spreadsheets().values().get(spreadsheetId=t["partner"], range=f"'{LIST_PARTNERA}'",
                                            valueRenderOption="FORMULA").execute().get("values", [])
    if staroe and staroe[0][:len(SHAPKA)] != SHAPKA:
        raise SystemExit(f"Стоп: шапка листа партнёра изменилась, ничего не пишу: {staroe[0]}")
    vse = sliyanie(staroe[1:], lyudi_partnera(papka, nastr.get("vladelec", ""), (nastr.get("partner") or {}).get("imya", "")),
                   podskazki_nikov(papka))
    svoi = lambda r: [bezopasno(c) for c in r[:4]] + r[4:8] + [bezopasno(r[8])]  # noqa: E731
    zapisat_list(sh, t["partner"], LIST_PARTNERA, [SHAPKA] + [svoi(r) for r in vse], len(staroe))
    foto = {p.stem for p in (Path(papka) / "foto").glob("*.*")}
    byla_kopiya = sh.spreadsheets().values().get(spreadsheetId=t["vladelec"], range=f"'{LIST_VLADELCA}'!A:A").execute().get("values", [])
    zapisat_list(sh, t["vladelec"], LIST_VLADELCA,
                 [SHAPKA + ["Фото в деке"]] + [svoi(r) + ["да" if r[8] in foto else "нет"] for r in vse], len(byla_kopiya))
    niki = {r[8]: str(r[4]).strip() for r in vse if r[8] and str(r[4]).strip()}
    out = Path(papka) / "dannye" / "niki_ot_partnera.json"
    out.write_text(json.dumps(niki, ensure_ascii=False, indent=1), encoding="utf-8")
    novye = sum(1 for r in vse if not r[8])
    print(f"{datetime.now():%d.%m %H:%M}: строк {len(vse)}, с ником {len(niki)}, новых от партнёра {novye} → {out}")


def main(argv=None):
    p = argparse.ArgumentParser(description="Лист партнёра для кругов")
    sub = p.add_subparsers(dest="command", required=True)
    sub.add_parser("sozdat")
    s = sub.add_parser("obnovit")
    s.add_argument("--papka", type=Path, required=True)
    a = p.parse_args(argv)
    sozdat() if a.command == "sozdat" else obnovit(a.papka)


if __name__ == "__main__":
    main()
