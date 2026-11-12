"""Дека круга: одна на всех участников, горизонталь 1600×900, PDF и снимки страниц.

Обложка — тема круга, общая мысль крупно в акцентной плашке, аватарки участников на равных
(до 5 в ряд, больше — два ряда помельче), модератор внизу. Дальше по слайду на участника:
фото, имя, строка о компании, интро 01–05 и тёмная полоса «С кем в круге».
Номер круга в деку не идёт: дека называется темой.
Выручка не подтверждена (vyruchka_ok: false) — еле заметная точка справа сверху у аватарки, без надписи.

Данные — рабочая папка партии кругов (--papka):
  dannye/krugi.json        состав: [{"n", "tema", "pokupatel", "probnyy"?, "lyudi": [{"k", "imya", "zovet"}]}]
  dannye/krug_<n>.json     тексты: {"n", "mysl", "lyudi": [{"k", "imya", "komp", "sub", "o1".."o5", "svyaz", "vyruchka_ok"?}]}
  foto/<k>.jpg|png         аватарки; нет фото — инициалы в круге
Настройки — private/nastroyka.json рядом со скриптом (образец nastroyka.example.json).

Запуск: python3 -I krug_deka.py --papka private/<партия> [номера кругов]
Нужен Playwright с Chromium: .venv/bin/pip install playwright && .venv/bin/playwright install chromium
"""
import argparse
import asyncio
import base64
import html as H
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent
NASTROYKA = ROOT / "private" / "nastroyka.json"
BLOKI = [("01", "Оффер"), ("02", "Для кого"), ("03", "Кейсы"), ("04", "Кто нужен"), ("05", "Что даёт взамен")]
PO_UMOLCHANIYU = {
    "brend": "", "sayt": "", "kicker": "Круг", "moderator": "", "podval": "Zoom ~1,5 часа · вход 0 ₽",
    "logo_svg": "", "shrift_zag": "Montserrat", "shrift_tekst": "Lora",
    "cveta": {"fon": "#F5F4EF", "tekst": "#222224", "akcent": "#E1006C", "akcent_svetlyy": "#FF4FA3", "tyomnyy": "#232325"},
}
PROBEL_MIN = 12  # px между последним блоком и полосой «С кем в круге» (или подвалом обложки)


def nastroyki(put=NASTROYKA):
    n = json.loads(json.dumps(PO_UMOLCHANIYU))
    if Path(put).exists():
        svoi = json.loads(Path(put).read_text(encoding="utf-8"))
        n.update({k: v for k, v in svoi.items() if k != "cveta"})
        n["cveta"].update(svoi.get("cveta", {}))
    return n


def md(t):
    """**жирный** → <b>, остальное экранируется."""
    return re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", H.escape(t or "", quote=False))


def initsialy(imya):
    return "".join(w[0] for w in (imya or "?").split()[:2]).upper()


def foto(p, cls, papka):
    """Аватарка в круге. vyruchka_ok == False — точка справа сверху; None или True — без метки."""
    if p.get("vyruchka_ok") is False:
        return f'<span class="sloy">{foto(dict(p, vyruchka_ok=None), cls, papka)}<i class="tochka {cls}t"></i></span>'
    for ext, mime in (("jpg", "jpeg"), ("png", "png")):
        f = Path(papka) / "foto" / f"{p['k']}.{ext}"
        if f.exists():
            return f'<img class="{cls}" src="data:image/{mime};base64,{base64.b64encode(f.read_bytes()).decode()}">'
    return f'<span class="{cls} ini">{H.escape(initsialy(p.get("imya")))}</span>'


def shapka(n):
    logo = f'<span class="logo">{n["logo_svg"]}{H.escape(n["brend"])}</span>'
    return f'<header>{logo}<span class="site">{H.escape(n["sayt"])}</span></header>'


def oblozhka(tema, mysl, lyudi, n, papka):
    kol = len(lyudi) if len(lyudi) <= 5 else (len(lyudi) + 1) // 2  # до 5 — один ряд, больше — два
    ryad = "".join(f'<div class="p">{foto(p, "big", papka)}<b>{H.escape(p["imya"])}</b>'
                   f'<span>{H.escape(p.get("komp", ""))}</span></div>' for p in lyudi)
    cls = "grid dva" if len(lyudi) > 5 else "grid"
    moder = f'Модератор — <b>{H.escape(n["moderator"])}</b> · ' if n["moderator"] else ""
    return f"""<section class="dark">
<header><span class="logo">{n["logo_svg"]}{H.escape(n["brend"])}</span><span class="kick">{H.escape(n["kicker"])}</span></header>
<h1>{H.escape(tema)}</h1>
<div class="mysl">{md(mysl)}</div>
<div class="{cls}" style="grid-template-columns:repeat({kol},1fr)">{ryad}</div>
<footer><span>{moder}{H.escape(n["podval"])}</span><span>Интро участников →</span></footer>
</section>"""


def slayd(p, n, papka):
    cols = "".join(f'<div class="blk"><span class="num">{num}</span><h4>{zag}</h4><p>{md(p.get("o" + str(i + 1)))}</p></div>'
                   for i, (num, zag) in enumerate(BLOKI))
    return f"""<section>{shapka(n)}
<div class="body">
 <div class="kto"><div class="ava">{foto(p, "port", papka)}</div><h2>{H.escape(p["imya"])}</h2><p>{H.escape(p.get("sub", ""))}</p></div>
 <div class="cols">{cols}</div>
</div>
<div class="idea"><h3>С кем в круге</h3><p>{md(p.get("svyaz"))}</p></div>
</section>"""


def css(n):
    c, zag, tekst = n["cveta"], n["shrift_zag"], n["shrift_tekst"]
    return f"""
@page{{size:1600px 900px;margin:0}}
*{{box-sizing:border-box;margin:0;padding:0;-webkit-print-color-adjust:exact;print-color-adjust:exact}}
body{{background:{c["fon"]};color:{c["tekst"]};font-family:{tekst},Georgia,serif}}
section{{position:relative;width:1600px;height:900px;padding:40px 60px;page-break-after:always;overflow:hidden;background:{c["fon"]}}}
section.dark{{background:{c["tyomnyy"]};color:{c["fon"]}}}
h1,h2,h3,h4,header,.kick,.num,footer,.grid b,.grid span,.mysl b,.ini{{font-family:{zag},Arial,sans-serif}}
header{{display:flex;justify-content:space-between;align-items:center;min-height:40px}}
.logo{{display:flex;align-items:center;gap:10px;font-weight:700;font-size:24px}}.logo svg{{width:40px;height:40px;color:{c["akcent"]}}}
.site{{font-weight:600;font-size:18px;color:#6B6A64}}
.kick{{color:{c["akcent_svetlyy"]};font-weight:600;font-size:20px;letter-spacing:.08em;text-transform:uppercase}}
h1{{font-weight:800;font-size:80px;line-height:1.02;letter-spacing:-.035em;margin:38px 0 24px;max-width:1400px}}
.mysl{{background:{c["akcent"]};color:#fff;border-radius:22px;padding:22px 32px;font-size:27px;line-height:1.38;max-width:1240px}}
.mysl b{{font-weight:800}}
.grid{{display:grid;gap:10px;margin-top:64px}}
.grid.dva{{margin-top:30px;row-gap:18px}}.grid.dva .big{{width:112px;height:112px}}.grid.dva span.big.ini{{font-size:40px}}
.grid.dva b{{font-size:17px;margin-top:8px}}.grid.dva span{{font-size:12.5px}}
.grid .p{{text-align:center}}
.big{{width:170px;height:170px;border-radius:50%;object-fit:cover;border:3px solid {c["akcent_svetlyy"]};display:block;margin:0 auto}}
.ini{{display:flex;align-items:center;justify-content:center;background:#3a3a3e;color:{c["akcent_svetlyy"]};font-weight:800}}
.grid span.ini,.kto span.ini{{display:flex;align-items:center;justify-content:center;padding:0;margin:0 auto;color:{c["akcent_svetlyy"]};line-height:1}}
.grid span.big.ini{{font-size:58px;margin-top:0}}.kto span.port.ini{{font-size:86px;margin:12px auto 22px}}
.grid b{{display:block;font-size:20px;margin-top:12px;line-height:1.25}}
.grid span{{display:block;font-size:14px;color:#a8a49c;margin-top:4px;line-height:1.3;padding:0 10px}}
footer{{position:absolute;left:60px;right:60px;bottom:30px;display:flex;justify-content:space-between;border-top:1px solid #3d3d42;padding-top:16px;font-size:18px;color:#c9c5bd}}
footer b{{color:{c["akcent_svetlyy"]}}}
.body{{display:grid;grid-template-columns:330px 1fr;gap:46px;margin-top:26px}}
.kto{{text-align:center}}
.ava{{position:relative;display:inline-block}}
.sloy{{position:relative;display:block;line-height:0;font-size:0}}
.tochka{{position:absolute;border-radius:50%;background:#8f8b83;opacity:.55}}
.bigt{{width:9px;height:9px;top:12px;left:calc(50% + 62px)}}
.grid.dva .bigt{{width:7px;height:7px;top:8px;left:calc(50% + 40px)}}
.portt{{width:12px;height:12px;top:30px;left:calc(50% + 92px)}}
.port{{width:240px;height:240px;border-radius:50%;object-fit:cover;outline:2px solid {c["akcent"]};outline-offset:9px;margin:12px auto 22px;display:flex}}
.port.ini{{background:{c["tyomnyy"]}}}
.kto h2{{font-weight:800;font-size:34px;line-height:1.1;letter-spacing:-.02em}}
.kto p{{font-size:20px;line-height:1.4;margin-top:10px;color:#3a3a3d}}
.cols{{display:grid;grid-template-columns:repeat(3,1fr);gap:22px 34px;align-content:start}}
.blk .num{{display:block;font-weight:600;font-size:44px;line-height:1;color:{c["akcent"]};letter-spacing:-1.5px}}
.blk h4{{font-weight:700;font-size:24px;margin:6px 0 6px}}
.blk p{{font-size:21px;line-height:1.42}}.blk p b{{font-weight:700}}
.idea{{position:absolute;left:30px;right:30px;bottom:26px;background:{c["tyomnyy"]};color:#fff;border-radius:24px;padding:20px 40px 22px}}
.idea h3{{font-weight:700;font-size:22px;color:{c["akcent_svetlyy"]}}}.idea p{{margin-top:6px;font-size:23px;line-height:1.4}}
"""


def html_kruga(krug, tekst, n, papka):
    """HTML деки. Состав и порядок — из krug_<n>.json: помощник мог заменить конкурента из запаса."""
    lyudi = tekst["lyudi"]
    stranicy = [oblozhka(krug["tema"], tekst["mysl"], lyudi, n, papka)] + [slayd(p, n, papka) for p in lyudi]
    shrifty = "family=" + "&family=".join(f.replace(" ", "+") + ":wght@400;500;600;700;800"
                                            for f in dict.fromkeys([n["shrift_zag"], n["shrift_tekst"]]))
    return (f'<!doctype html><html lang="ru"><head><meta charset="utf-8"><title>{H.escape(n["kicker"])} — {H.escape(krug["tema"])}</title>'
            f'<link href="https://fonts.googleapis.com/css2?{shrifty}&subset=cyrillic&display=swap" rel="stylesheet">'
            f'<style>{css(n)}</style></head><body>{"".join(stranicy)}</body></html>')


def bezopasnoe_imya(t):
    return re.sub(r'[\\/:*?"<>|]+', " ", t).strip()


def imya_pdf(papka, krug, n):
    return Path(papka) / "pdf" / f"{bezopasnoe_imya(n['kicker'])} — {bezopasnoe_imya(krug['tema'])}.pdf"


def gotovye(papka, nomera=None, fayl="krugi.json"):
    d = Path(papka) / "dannye"
    vse = json.loads((d / fayl).read_text(encoding="utf-8"))
    return [k for k in vse if (not nomera or k["n"] in nomera) and (d / f"krug_{k['n']}.json").exists()]


PROVERKA_NAEZDA = """[...document.querySelectorAll('section')].map((s,i)=>{
  const r=s.getBoundingClientRect(), idea=s.querySelector('.idea'), foot=s.querySelector('footer');
  const last=[...s.querySelectorAll('.cols,.grid')].pop();
  const lb=last?last.getBoundingClientRect().bottom:0;
  const it=idea?idea.getBoundingClientRect().top:(foot?foot.getBoundingClientRect().top:r.bottom);
  return [i+1, Math.round(it-lb)]})"""


async def pechat(papka, krugi, n):
    from playwright.async_api import async_playwright
    papka = Path(papka)
    (papka / "pdf").mkdir(exist_ok=True)
    (papka / "html").mkdir(exist_ok=True)
    plohie_vse = []
    async with async_playwright() as p:
        b = await p.chromium.launch()  # без channel: обычный Chrome на Маке встаёт в Dock на каждый кадр
        pg = await b.new_page(viewport={"width": 1600, "height": 900})
        for k in krugi:
            tekst = json.loads((papka / "dannye" / f"krug_{k['n']}.json").read_text(encoding="utf-8"))
            src = papka / "html" / f"krug_{k['n']}.html"
            src.write_text(html_kruga(k, tekst, n, papka), encoding="utf-8")
            await pg.goto(src.resolve().as_uri(), wait_until="networkidle")
            await pg.evaluate("document.fonts.ready")
            await pg.wait_for_timeout(400)
            probely = await pg.evaluate(PROVERKA_NAEZDA)
            plohie = [x for x in probely if x[1] < PROBEL_MIN]
            plohie_vse += [(k["n"], x) for x in plohie]
            print(f"{k['n']}. {k['tema']}:", "ок" if not plohie else f"НАЕЗД на страницах {[x[0] for x in plohie]}")
            pdir = papka / "png" / str(k["n"])
            pdir.mkdir(parents=True, exist_ok=True)
            for i, s in enumerate(await pg.query_selector_all("section")):
                await s.screenshot(path=str(pdir / f"str_{i + 1:02d}.png"))
            await pg.pdf(path=str(imya_pdf(papka, k, n)), width="1600px", height="900px", print_background=True)
        await b.close()
    return plohie_vse


def main(argv=None):
    a = argparse.ArgumentParser(description="Деки кругов: PDF 1600×900 и снимки страниц")
    a.add_argument("--papka", required=True, help="рабочая папка партии кругов")
    a.add_argument("--fayl", default="krugi.json", help="файл состава в dannye/ (по умолчанию krugi.json)")
    a.add_argument("nomera", nargs="*", type=int)
    a = a.parse_args(argv)
    krugi = gotovye(a.papka, set(a.nomera), a.fayl)
    if not krugi:
        raise SystemExit("Нечего собирать: нет krug_<n>.json для этих кругов.")
    plohie = asyncio.run(pechat(a.papka, krugi, nastroyki()))
    print("Собрано:", len(krugi), "· PDF в", Path(a.papka) / "pdf")
    if plohie:
        raise SystemExit(f"Текст наезжает на полосу внизу: {plohie}. Сократи блоки этих людей и собери заново.")


if __name__ == "__main__":
    main()
