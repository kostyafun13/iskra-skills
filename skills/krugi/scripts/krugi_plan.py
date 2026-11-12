"""Закреп-план рабочей группы кругов: тема, «Охота», люди с никами, кто пишет.

На круг — блок: «<n>. <тема>», «Охота: <ЛПР и компании покупателя>», строка на человека.
- Человека зовёт владелец — «· пишет <владелец>», без ника: свои контакты владелец партнёру не отдаёт.
- Есть ник — «@ник»; нет — «· ника нет».
- Выручка не подтверждена (vyruchka_ok: false) — «(?)»: после «интересно» спрашиваем выручку.
- Пробный круг: у сильного своего с выручкой — «· якорь 30+».
Сообщение Telegram — до 4096 знаков, поэтому план режется на части по границам кругов.

Ники собираются из трёх файлов в dannye/ (первый важнее): niki.json (вписал владелец),
niki_ot_partnera.json (лист партнёра), niki_po_telefonu.json (поиск по телефону). Ключ — поле k человека.

Запуск: python3 -I krugi_plan.py --papka private/<партия> [--fayl krugi_proby.json --probnye]
Итог: dannye/plan.json (или plan_probnye.json) — список текстов сообщений.
"""
import argparse
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent
PREDEL = 4096


def chitat(f, d):
    f = Path(f)
    return json.loads(f.read_text(encoding="utf-8")) if f.exists() else d


def chistyy_nik(t):
    """«@ник (по телефону)», «https://t.me/ник», «ник» → «ник». Пусто или не ник → ""."""
    t = (t or "").strip()
    if not t:
        return ""
    t = t.split()[0]
    t = re.sub(r"^(https?://)?(t\.me|telegram\.me)/", "", t).lstrip("@").strip("/,;")
    return t if re.fullmatch(r"[A-Za-z][A-Za-z0-9_]{3,31}", t) else ""


def niki(papka):
    """Источники по важности: niki.json → лист партнёра → поиск по телефону. Пустой или мусорный ник
    из важного источника не стирает верный ник из менее важного."""
    d = Path(papka) / "dannye"
    po_tel = {k: v.get("nik", "") for k, v in chitat(d / "niki_po_telefonu.json", {}).items() if isinstance(v, dict)}
    itog = {}
    for istochnik in (po_tel, chitat(d / "niki_ot_partnera.json", {}), chitat(d / "niki.json", {})):
        for k, v in istochnik.items():
            if n := chistyy_nik(v):
                itog[k] = n
    return itog


def kto_zovet(zovet, vladelec, partner=""):
    """«vladelec», «partner» или «neizvestno». Неизвестно — как у владельца: ник не показываем, партнёру не отдаём.
    Почему: помощник мог заменить человека и не перенести zovet — контакт владельца не должен утечь партнёру."""
    z = (zovet or "").strip().lower()
    if not z:
        return "neizvestno"
    if z.startswith("владелец") or vladelec and z.startswith(vladelec.strip().lower()):
        return "vladelec"
    if z.startswith("партнёр") or z.startswith("партнер") or partner and z.startswith(partner.strip().lower()):
        return "partner"
    return "neizvestno"


def zovet_vladelec(zovet, vladelec):
    return kto_zovet(zovet, vladelec) == "vladelec"


def stroka(p, zovet, nik, vladelec, probnyy=False, partner=""):
    imya = p["imya"]
    kto = kto_zovet(zovet, vladelec, partner)
    if kto == "vladelec":
        s = f"— {imya} · пишет {vladelec or 'владелец'}"
    elif kto == "neizvestno":
        s = f"— {imya} · кто зовёт — не указано"
    elif nik:
        s = f"— {imya} @{nik}"
    else:
        s = f"— {imya} · ника нет"
    if p.get("vyruchka_ok") is False:
        s += " (?)"
    elif probnyy and p.get("vyruchka_ok") is True:
        s += " · якорь 30+"
    return s


def blok(krug, tekst, nk, vladelec, partner=""):
    zovut = {p["k"]: p.get("zovet", "") for p in krug.get("lyudi", [])}
    probnyy = bool(krug.get("probnyy"))
    lines = [f"{krug['n']}. {krug['tema']}", f"Охота: {krug.get('ohota') or krug.get('pokupatel', '')}"]
    for p in tekst["lyudi"]:
        z = p.get("zovet") or zovut.get(p["k"], "")
        lines.append(stroka(p, z, nk.get(p["k"], "") or chistyy_nik(p.get("nik")), vladelec, probnyy, partner))
    return "\n".join(lines)


def shapka(vsego, vladelec, partner, ssylka, probnye):
    if probnye:
        return ("Пробные круги — выручка неизвестна\n\n"
                "Внятные фаундеры из чатов: свой софт, понятный продукт, первые клиенты. Выручку не знаем.\n"
                "Как зовём: обычное приглашение — подпись под декой. Ответил «интересно» → спрашиваем выручку "
                "суммой по всем проектам → решаем, берём ли.\n"
                "В каждом круге сильные свои с выручкой 30+ — чтобы откликнуться было интереснее.")
    t = (f"Круги — {vsego}, быстрый просмотр\n\n"
         "В круге фаундеры со своим софтом и одним общим покупателем. Согласятся не все — встреча из тех, кто ответил «да». "
         "Подпись под декой — приглашение, пересылать как есть.\n"
         f"@ник — пишет {partner or 'партнёр'}. «пишет {vladelec or 'владелец'}» — зовёт {vladelec or 'владелец'}. "
         "Нет ника — ищем ник.\n"
         "(?) — выручка неизвестна: после «интересно» спрашиваем выручку. В деке — точка у аватарки.")
    if ssylka:
        t += f"\nНики и статусы — лист партнёра: {ssylka}"
    return t


def dlina(t):
    """Длина так, как её считает Telegram: в единицах UTF-16 (эмодзи — две)."""
    return len(t.encode("utf-16-le")) // 2


def _razrezat(golova, bloki, byudzhet):
    chasti, tek = [], golova
    for b in bloki:
        if dlina(tek) + 2 + dlina(b) > byudzhet and tek:
            chasti.append(tek)
            tek = b
        else:
            tek = tek + "\n\n" + b if tek else b
    chasti.append(tek)
    if len(chasti) > 1:
        nazv = golova.split("\n", 1)[0]
        chasti = [chasti[0].replace(nazv, f"{nazv} (1/{len(chasti)})", 1)] + \
                 [f"{nazv} ({i + 2}/{len(chasti)})\n\n{c}" for i, c in enumerate(chasti[1:])]
    return [c.rstrip() for c in chasti]  # без переноса в конце: иначе отправка не сверит текст


def razrezat(golova, bloki, predel=PREDEL):
    """Части до predel знаков (UTF-16), круг не рвётся. К частям — «(i/N)» в заголовке.
    Запас под заголовок части растёт, пока все части не влезут."""
    nazv = golova.split("\n", 1)[0]
    for b in bloki:
        if dlina(b) + dlina(nazv) + 12 > predel:
            raise ValueError(f"Один круг длиннее сообщения Telegram: {b[:60]}…")
    zapas = dlina(nazv) + 12
    while True:
        chasti = _razrezat(golova, bloki, predel - zapas)
        if max(dlina(c) for c in chasti) <= predel:
            return chasti
        zapas += 20


def sobrat_plan(papka, fayl="krugi.json", probnye=False, nastr=None):
    nastr = nastr or {}
    d = Path(papka) / "dannye"
    krugi = json.loads((d / fayl).read_text(encoding="utf-8"))
    nk = niki(papka)
    vladelec = nastr.get("vladelec", "")
    partner = (nastr.get("partner") or {}).get("imya", "")
    bloki = []
    for k in krugi:
        f = d / f"krug_{k['n']}.json"
        if f.exists():
            bloki.append(blok(dict(k, probnyy=k.get("probnyy") or probnye), json.loads(f.read_text(encoding="utf-8")),
                              nk, vladelec, partner))
    ssylka = (nastr.get("partner") or {}).get("ssylka", "")
    return razrezat(shapka(len(bloki), vladelec, partner, ssylka, probnye), bloki)


def main(argv=None):
    a = argparse.ArgumentParser(description="Текст закреп-плана кругов")
    a.add_argument("--papka", required=True)
    a.add_argument("--fayl", default="krugi.json")
    a.add_argument("--probnye", action="store_true", help="пробные круги: своя шапка и пометка «якорь 30+»")
    a = a.parse_args(argv)
    if a.probnye and a.fayl == "krugi.json":
        a.fayl = "krugi_proby.json"
    nastr = chitat(ROOT / "private" / "nastroyka.json", {})
    chasti = sobrat_plan(a.papka, a.fayl, a.probnye, nastr)
    out = Path(a.papka) / "dannye" / ("plan_probnye.json" if a.probnye else "plan.json")
    out.write_text(json.dumps(chasti, ensure_ascii=False, indent=1), encoding="utf-8")
    print(f"План: {len(chasti)} сообщ., знаков {[len(c) for c in chasti]} → {out}")


if __name__ == "__main__":
    main()
