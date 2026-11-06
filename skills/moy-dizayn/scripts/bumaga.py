#!/usr/bin/env python3
"""Подложка для интро-карточки: рваная бумага на прозрачном фоне.

Рисует PNG кодом, без нейросети и без сети. Нужны pillow и numpy.

    python3 bumaga.py --out podlozhka.png
    python3 bumaga.py --out poloska.png --poloska

--poloska — полоска бумаги, чтобы положить её поверх нижнего среза фото.
Меняй --seed, чтобы у разных людей рисунок отличался.
"""
import argparse

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

K = 2  # внутреннее разрешение: PNG в 2 раза больше логического размера
BEZHEVAYA, PESOK, SVETLAYA, KRAFT, BLEDNAYA = (
    (226, 216, 197), (214, 202, 180), (236, 229, 215), (199, 184, 158), (242, 237, 226))


def shum(h, w, masshtab, rng):
    a = rng.random((max(2, int(h / masshtab) + 2), max(2, int(w / masshtab) + 2)))
    img = Image.fromarray((a * 255).astype("uint8")).resize((w, h), Image.BICUBIC)
    return np.asarray(img, float) / 255 - 0.5


def sloi(h, w, masshtaby, vesa, rng):
    return sum(shum(h, w, m * K, rng) * v for m, v in zip(masshtaby, vesa))


def kusok(w, h, cvet, seed, razryv=7, kromka=7, kamen=False):
    """Один кусок бумаги: рваный край, светлая кромка, волокна и крапинки."""
    w, h, razryv, kromka = w * K, h * K, razryv * K, kromka * K
    rng = np.random.default_rng(seed)
    y, x = np.mgrid[0:h, 0:w]
    storony = np.stack([x, w - 1 - x, y, h - 1 - y]).astype(float)
    d = storony.min(0) - razryv * 1.8 + sloi(h, w, [70, 26, 10, 4, 1.8], [.7, .6, .55, .42, .3], rng) * razryv * 2
    alfa = np.clip(d / 1.3 + .5, 0, 1)
    shirina = kromka * rng.uniform(.25, 1.5, 4)[storony.argmin(0)] * (
        .45 + 1.3 * np.clip(sloi(h, w, [55, 18, 6], [1, .6, .35], rng) + .45, 0, 1))
    na_kromke = np.clip((shirina - d) / (1.7 * K), 0, 1)
    if kamen:
        v = np.clip(.46 + sloi(h, w, [44, 18, 7, 3, 1.4], [1, .85, .75, .65, .55], rng) * 1.25, 0, 1) ** 2
        c = np.stack([36 + v * 128, 36 + v * 126, 35 + v * 122], -1)
    else:
        myatost = sloi(h, w, [90, 35], [1, .5], rng)
        ten = (1 + sloi(h, w, [130, 50], [1, .5], rng) * .03 + sloi(h, w, [7, 3, 1.4], [1, .9, .8], rng) * .042
               + (np.gradient(myatost, axis=1) + np.gradient(myatost, axis=0)) * 3)
        c = np.array(cvet, float)[None, None] * ten[..., None] + rng.normal(0, 1.5, (h, w, 1))
        volokna = Image.new("L", (w, h), 128)
        ris = ImageDraw.Draw(volokna)
        for _ in range(int(w * h / (1100 * K))):
            x0, y0, ugol, dlina = rng.integers(0, w), rng.integers(0, h), rng.uniform(0, 6.28), rng.uniform(5, 20) * K
            ris.line([x0, y0, x0 + np.cos(ugol) * dlina, y0 + np.sin(ugol) * dlina],
                     fill=int(rng.choice([104, 152])), width=1)
        c = c + (np.asarray(volokna.filter(ImageFilter.GaussianBlur(.6)), float) - 128)[..., None] * .3
    c = c * (1 - na_kromke[..., None]) + (np.array((250, 247, 240.))[None, None]
                                          + rng.normal(0, 2, (h, w, 1))) * na_kromke[..., None]
    return Image.fromarray(np.dstack([np.clip(c, 0, 255), alfa * 255]).astype("uint8"), "RGBA")


def polozhit(holst, kus, x, y, ugol=0):
    kus = kus.rotate(ugol, Image.BICUBIC, expand=True)
    ten = Image.new("RGBA", kus.size, (30, 24, 18, 0))
    ten.putalpha(kus.split()[3].point(lambda v: int(v * .3)))
    pole = 30 * K
    sloy = Image.new("RGBA", (kus.width + 2 * pole, kus.height + 2 * pole), (0, 0, 0, 0))
    sloy.paste(ten, (pole, pole), ten)
    sloy = sloy.filter(ImageFilter.GaussianBlur(5 * K))
    holst.alpha_composite(sloy, (max(0, int((x + 3) * K) - pole), max(0, int((y + 6) * K) - pole)))
    holst.alpha_composite(kus, (max(0, int(x * K)), max(0, int(y * K))))


# доли от размера: ширина, высота, x, y, угол, цвет (None — тёмный кусок с фактурой)
PLAN = [(.47, .18, .14, .06, 6, SVETLAYA), (.39, .17, .47, .05, -7, PESOK), (.63, .58, .19, .11, -2, BEZHEVAYA),
        (.25, .32, .10, .27, 5, BLEDNAYA), (.22, .29, .72, .26, -4, KRAFT), (.30, .22, .66, .12, 6, SVETLAYA),
        (.30, .23, .09, .57, -4, None), (.23, .24, .71, .54, 5, PESOK), (.67, .29, .17, .63, 2, BEZHEVAYA),
        (.36, .14, .10, .79, -6, SVETLAYA), (.34, .13, .55, .80, 5, KRAFT)]
POLOSKA = [(.52, .40, .06, .28, -5, BLEDNAYA), (.60, .46, .37, .24, 4, BEZHEVAYA), (.68, .36, .17, .40, -1, SVETLAYA)]


def sobrat(w, h, plan, seed):
    holst = Image.new("RGBA", (w * K, h * K), (0, 0, 0, 0))
    for i, (kw, kh, kx, ky, ugol, cvet) in enumerate(plan):
        kus = kusok(int(kw * w), int(kh * h), cvet, seed + i * 7, kamen=cvet is None)
        polozhit(holst, kus, kx * w, ky * h, ugol)
    return holst


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--out", required=True)
    p.add_argument("--w", type=int, help="ширина, по умолчанию 640")
    p.add_argument("--h", type=int, help="высота, по умолчанию 1040, у полоски 300")
    p.add_argument("--seed", type=int, default=100)
    p.add_argument("--poloska", action="store_true")
    a = p.parse_args()
    w, h = a.w or 640, a.h or (300 if a.poloska else 1040)
    sobrat(w, h, POLOSKA if a.poloska else PLAN, a.seed).save(a.out)
    print(f"Готово: {a.out}")


if __name__ == "__main__":
    main()
