#!/usr/bin/env python3
"""Son N dikteyi geçmişten çekip kıyas dosyasına yazar.

    python3 gecmisten-al.py katip        # son 8 kaydı katip.txt'e
    python3 gecmisten-al.py katip 8

Elle kopyala-yapıştır adımını atlar; sıra karışmaz.
"""
import json, sys
from pathlib import Path

HERE = Path(__file__).parent
HISTORY = Path.home() / "Library/Application Support/Katip/history.jsonl"

def main():
    if len(sys.argv) < 2:
        sys.exit("kullanım: gecmisten-al.py <isim> [adet]")
    name = sys.argv[1]
    count = int(sys.argv[2]) if len(sys.argv) > 2 else len(
        [l for l in (HERE / "cumleler.txt").read_text(encoding="utf-8").splitlines()
         if l.strip() and not l.startswith("#")])

    if not HISTORY.exists():
        sys.exit(f"geçmiş dosyası yok: {HISTORY}")

    records = []
    for line in HISTORY.read_text(encoding="utf-8").splitlines():
        if line.strip():
            try:
                records.append(json.loads(line))
            except json.JSONDecodeError:
                pass

    if len(records) < count:
        sys.exit(f"geçmişte {len(records)} kayıt var, {count} gerekiyor")

    # Dosya eskiden yeniye; son `count` kaydı söylenme sırasıyla al.
    picked = records[-count:]
    out = HERE / f"{name}.txt"
    out.write_text("\n".join(r["text"].strip() for r in picked) + "\n", encoding="utf-8")

    print(f"✔ {out.name} yazıldı ({count} kayıt)\n")
    for i, r in enumerate(picked, 1):
        print(f"{i:2d}. {r['text']}")

if __name__ == "__main__":
    main()
