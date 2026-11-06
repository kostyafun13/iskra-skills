import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from PIL import Image

SKRIPT = Path(__file__).resolve().parents[1] / "scripts" / "bumaga.py"


class Bumaga(unittest.TestCase):
    def sdelat(self, *dop):
        with tempfile.TemporaryDirectory() as t:
            out = Path(t) / "b.png"
            subprocess.run([sys.executable, str(SKRIPT), "--out", str(out), "--w", "200", "--h", "320", *dop], check=True)
            with Image.open(out) as im:
                return im.mode, im.size, im.getchannel("A").getextrema()

    def test_podlozhka_prozrachnaya(self):
        rezhim, razmer, alfa = self.sdelat()
        self.assertEqual((rezhim, razmer), ("RGBA", (400, 640)))
        self.assertEqual(alfa, (0, 255))

    def test_poloska(self):
        self.assertEqual(self.sdelat("--poloska")[0], "RGBA")


if __name__ == "__main__":
    unittest.main()
