"""Write assets/qr.svg: the QR code delegates scan to open the quiz."""
from pathlib import Path

import segno

URL = "https://samharrison7.github.io/ic1-quiz/"

out = Path(__file__).resolve().parent.parent / "assets" / "qr.svg"
segno.make(URL, error="m").save(str(out), border=2, dark="#000000", light="#ffffff", xmldecl=False, omitsize=True, svgns=True, nl=False)
print(f"Wrote {out} for {URL}")
