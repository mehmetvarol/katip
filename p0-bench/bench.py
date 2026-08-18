#!/usr/bin/env python3
"""Katip P0 kalite tezgâhı — 4 konfigürasyonu aynı seslerde yan yana ölçer.

    python bench.py                     # hepsini çalıştır
    python bench.py --configs tr tr+hotwords
    python bench.py --model large-v3    # başka model dene

Ölçülen şey ham WER DEĞİL. Asıl soru: "Türkçe cümlemin içindeki İngilizce teknik
terimler İngilizce yazımıyla korunuyor mu?" → term_retention sütunu.
WER ikincil (Türkçe morfolojinin bozulup bozulmadığını gösterir).
"""

import argparse
import json
import time
import wave
from datetime import datetime
from pathlib import Path

from corpus import AUDIO, SILENCE_ID, load_glossary, load_sentences, term_hits, wer

RESULTS = Path(__file__).parent / "results"

# Tüm konfigürasyonlarda sabit tutulanlar — değişkeni tek başına izleyebilmek için.
COMMON = dict(
    beam_size=5,
    temperature=0,
    vad_filter=True,
    condition_on_previous_text=False,  # kısa katip için: tekrar/sürüklenme önler
)


def build_configs(glossary):
    return {
        "auto":        dict(language=None),
        "tr":          dict(language="tr"),
        "tr+hotwords": dict(language="tr", hotwords=glossary),
        "multilingual": dict(language=None, multilingual=True),
    }


def check_glossary_budget(model, glossary):
    """hotwords bütçesi: aşılırsa SONDAN kırpılır, yani son terimler sessizce düşer."""
    try:
        n = len(model.hf_tokenizer.encode(" " + glossary.strip()).ids)
    except Exception:
        return
    budget = model.max_length // 2 - 1
    if n >= budget:
        print(f"  ⚠️  glossary {n} token — bütçe {budget}. Sondaki terimler KIRPILACAK.")
        print("      Kritik terimleri glossary.txt'in BAŞINA taşı veya listeyi kısalt.")
    else:
        print(f"  glossary: {n}/{budget} token")


def audio_duration(path):
    with wave.open(str(path)) as w:
        return w.getnframes() / w.getframerate()


def transcribe(model, path, opts):
    start = time.perf_counter()
    segments, info = model.transcribe(str(path), **COMMON, **opts)
    text = " ".join(s.text.strip() for s in segments).strip()
    return text, time.perf_counter() - start, info.language


def run_config(model, name, opts, items):
    rows = []
    for s in items:
        path = AUDIO / f"{s['id']}.wav"
        if not path.exists():
            continue
        text, elapsed, lang = transcribe(model, path, opts)
        found, missed = term_hits(s["terms"], text)
        rows.append({
            "id": s["id"],
            "reference": s["reference"],
            "hypothesis": text,
            "detected_language": lang,
            "wer": wer(s["reference"], text),
            "terms_found": found,
            "terms_missed": missed,
            "term_retention": len(found) / len(s["terms"]) if s["terms"] else None,
            "seconds": elapsed,
            "rtf": elapsed / audio_duration(path),
        })
        print(f"  #{s['id']} [{lang}] {text[:70]}")

    hall = None
    silence = AUDIO / f"{SILENCE_ID}.wav"
    if silence.exists():
        text, _, _ = transcribe(model, silence, opts)
        hall = text
        print(f"  sessizlik → {'✔ boş' if not text else f'⚠️  HALÜSİNASYON: {text!r}'}")

    scored = [r for r in rows if r["term_retention"] is not None]
    return {
        "config": name,
        "options": {k: (v[:60] + "..." if k == "hotwords" and v else v) for k, v in opts.items()},
        "rows": rows,
        "hallucination": hall,
        "mean_wer": sum(r["wer"] for r in rows) / len(rows) if rows else None,
        "term_retention": (sum(r["term_retention"] for r in scored) / len(scored)) if scored else None,
        "mean_rtf": sum(r["rtf"] for r in rows) / len(rows) if rows else None,
    }


def summary_table(results):
    head = ("| Konfigürasyon | Terim korunumu | Ort. WER | RTF | Sessizlikte halüsinasyon |\n"
            "|---|---|---|---|---|\n")
    lines = []
    for r in results:
        hall = "—" if not r["hallucination"] else f"⚠️ `{r['hallucination'][:40]}`"
        if r["hallucination"] == "":
            hall = "✔ yok"
        lines.append(
            f"| `{r['config']}` | **{r['term_retention']:.0%}** | {r['mean_wer']:.1%} "
            f"| {r['mean_rtf']:.2f}x | {hall} |"
        )
    return head + "\n".join(lines)


def write_report(results, model_name, compute_type, path):
    lines = [
        f"# Katip P0 sonuçları — {datetime.now():%Y-%m-%d %H:%M}",
        "",
        f"Model: `{model_name}` · compute_type: `{compute_type}` · "
        f"cihaz: **CPU** (CTranslate2'nin Metal/ANE backend'i yok)",
        "",
        "> RTF = geçen süre / ses süresi. Düşük iyi. Bu sayılar **CPU** sayıları;",
        "> ürün motoru WhisperKit ANE'de belirgin şekilde hızlı olacak.",
        "> Buradaki asıl çıktı hız değil, **terim korunumu**.",
        "",
        "## Özet",
        "",
        summary_table(results),
        "",
        "## Cümle bazında",
    ]
    for r in results:
        lines += ["", f"### `{r['config']}`", ""]
        for row in r["rows"]:
            mark = "✔" if not row["terms_missed"] else "✗"
            lines.append(f"- {mark} **#{row['id']}** [{row['detected_language']}] "
                         f"WER {row['wer']:.0%}")
            lines.append(f"    - ref: {row['reference']}")
            lines.append(f"    - hyp: {row['hypothesis']}")
            if row["terms_missed"]:
                lines.append(f"    - **kaçan terimler:** {', '.join(row['terms_missed'])}")
    path.write_text("\n".join(lines), encoding="utf-8")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default="large-v3-turbo")
    ap.add_argument("--compute-type", default="int8")
    ap.add_argument("--configs", nargs="+")
    args = ap.parse_args()

    items = load_sentences()
    have = [s for s in items if (AUDIO / f"{s['id']}.wav").exists()]
    if not have:
        print("audio/ boş. Önce:  python record.py")
        return 1
    print(f"{len(have)}/{len(items)} cümle kayıtlı.\n")

    from faster_whisper import WhisperModel

    print(f"Model yükleniyor: {args.model} ({args.compute_type}, CPU)...")
    t0 = time.perf_counter()
    model = WhisperModel(args.model, device="cpu", compute_type=args.compute_type)
    print(f"  yüklendi ({time.perf_counter() - t0:.1f} sn)\n")

    glossary = load_glossary()
    check_glossary_budget(model, glossary)
    print()

    configs = build_configs(glossary)
    if args.configs:
        configs = {k: v for k, v in configs.items() if k in args.configs}

    results = []
    for name, opts in configs.items():
        print(f"▶ {name}")
        results.append(run_config(model, name, opts, have))
        print()

    RESULTS.mkdir(exist_ok=True)
    stamp = datetime.now().strftime("%Y-%m-%d-%H%M")
    (RESULTS / f"{stamp}.json").write_text(
        json.dumps({"model": args.model, "compute_type": args.compute_type,
                    "common": COMMON, "results": results}, ensure_ascii=False, indent=2),
        encoding="utf-8")
    report = RESULTS / f"{stamp}.md"
    write_report(results, args.model, args.compute_type, report)

    print(summary_table(results))
    print(f"\nRapor → {report}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
