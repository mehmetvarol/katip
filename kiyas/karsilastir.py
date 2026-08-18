#!/usr/bin/env python3
"""Katip ile rakip dikte uygulamalarını AYNI cümleler üzerinde kıyaslar.

Kullanım:
    1. cumleler.txt'teki cümleleri sırayla her uygulamaya söyle
    2. Çıktıları katip.txt / wispr.txt / superwhisper.txt dosyalarına
       satır satır yapıştır (cümle başına bir satır, aynı sıra)
    3. python3 karsilastir.py

Ölçtüğü şey ham WER değil: asıl metrik **terim korunumu** — Türkçe cümlenin
içindeki İngilizce teknik terim İngilizce yazımıyla mı çıkıyor?
Bağımlılık yok, sistem python3'ü yeter.
"""
import re, sys, unicodedata
from pathlib import Path

HERE = Path(__file__).parent

def normalize(text):
    text = text.replace("İ", "i").replace("I", "ı")
    text = text.lower()
    text = unicodedata.normalize("NFC", text)
    text = re.sub(r"[^\w\sçğıöşü]", " ", text)
    return re.sub(r"\s+", " ", text).strip()

def load_cases():
    """cumleler.txt: İngilizce terimler `backtick` içinde."""
    cases = []
    for line in (HERE / "cumleler.txt").read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        terms = re.findall(r"`([^`]+)`", line)
        cases.append({"reference": line.replace("`", ""), "terms": terms})
    return cases

def term_hits(hypothesis, terms):
    """Terim, Türkçe ek almış olsa da sayılır: component'i, hook'a ..."""
    norm = normalize(hypothesis)
    return [t for t in terms if normalize(t) in norm]

def wer(reference, hypothesis):
    r, h = normalize(reference).split(), normalize(hypothesis).split()
    if not r:
        return 0.0
    d = [[0] * (len(h) + 1) for _ in range(len(r) + 1)]
    for i in range(len(r) + 1): d[i][0] = i
    for j in range(len(h) + 1): d[0][j] = j
    for i in range(1, len(r) + 1):
        for j in range(1, len(h) + 1):
            cost = 0 if r[i-1] == h[j-1] else 1
            d[i][j] = min(d[i-1][j] + 1, d[i][j-1] + 1, d[i-1][j-1] + cost)
    return d[len(r)][len(h)] / len(r)

def main():
    cases = load_cases()
    files = {p.stem: p for p in HERE.glob("*.txt") if p.name != "cumleler.txt"}
    if not files:
        sys.exit("Çıktı dosyası yok. katip.txt / wispr.txt oluştur ve içine\n"
                 "her cümlenin transkriptini ayrı satır olarak yapıştır.")

    results = {}
    for name, path in sorted(files.items()):
        lines = [l for l in path.read_text(encoding="utf-8").splitlines() if l.strip()]
        if len(lines) != len(cases):
            print(f"⚠️  {name}: {len(lines)} satır var, {len(cases)} bekleniyor — atlanıyor\n")
            continue
        hits = total = 0
        wers, misses = [], []
        for case, hyp in zip(cases, lines):
            found = term_hits(hyp, case["terms"])
            hits += len(found); total += len(case["terms"])
            misses += [t for t in case["terms"] if t not in found]
            wers.append(wer(case["reference"], hyp))
        results[name] = {
            "terim": 100 * hits / total if total else 0,
            "wer": 100 * sum(wers) / len(wers),
            "kacan": misses,
        }

    if not results:
        return
    print(f"\n{len(cases)} cümle · {sum(len(c['terms']) for c in cases)} beklenen terim\n")
    print(f"{'uygulama':<16}{'terim korunumu':>16}{'WER':>10}")
    print("-" * 42)
    for name, r in sorted(results.items(), key=lambda x: -x[1]["terim"]):
        print(f"{name:<16}{r['terim']:>15.0f}%{r['wer']:>9.0f}%")
    print()
    for name, r in results.items():
        if r["kacan"]:
            print(f"{name} — kaçırdığı terimler: {', '.join(sorted(set(r['kacan'])))}")

if __name__ == "__main__":
    main()
