"""sentences.txt / glossary.txt okuma ve Türkçe metin normalizasyonu."""

import re
import unicodedata
from pathlib import Path

BASE = Path(__file__).parent
AUDIO = BASE / "audio"
SILENCE_ID = "silence"

# Türkçe'ye özgü: Python'un .lower()'ı 'I' -> 'i' verir, Türkçe'de 'ı' olmalı.
_TR_LOWER = str.maketrans({"I": "ı", "İ": "i"})


def _strip_comments(path):
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            yield line


def load_sentences():
    """[{id, reference, terms}] döndürür. Terimler `backtick` içinden çıkarılır."""
    items = []
    for i, line in enumerate(_strip_comments(BASE / "sentences.txt"), start=1):
        terms = re.findall(r"`([^`]+)`", line)
        items.append({
            "id": f"{i:02d}",
            "reference": line.replace("`", ""),
            "terms": terms,
        })
    return items


def load_glossary():
    """hotwords için tek satırlık virgülle ayrılmış terim listesi."""
    parts = []
    for line in _strip_comments(BASE / "glossary.txt"):
        parts.extend(p.strip() for p in line.split(",") if p.strip())
    seen, out = set(), []
    for p in parts:
        if p.lower() not in seen:
            seen.add(p.lower())
            out.append(p)
    return ", ".join(out)


def normalize(text):
    """WER ve terim eşleşmesi için: Türkçe-doğru küçültme, noktalama temizliği."""
    text = unicodedata.normalize("NFC", text)
    text = text.translate(_TR_LOWER).lower()
    text = text.replace("'", "'").replace("`", "")
    # kesme işaretini boşluğa çevir: "component'i" -> "component i"
    text = re.sub(r"['´]", " ", text)
    text = re.sub(r"[^\w\sğüşıöç]", " ", text)
    return re.sub(r"\s+", " ", text).strip()


def wer(reference, hypothesis):
    """Kelime düzeyi Levenshtein / referans uzunluğu."""
    ref = normalize(reference).split()
    hyp = normalize(hypothesis).split()
    if not ref:
        return 0.0 if not hyp else 1.0

    prev = list(range(len(hyp) + 1))
    for i, r in enumerate(ref, start=1):
        cur = [i]
        for j, h in enumerate(hyp, start=1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (r != h)))
        prev = cur
    return prev[-1] / len(ref)


def term_hits(terms, hypothesis):
    """(bulunan, kaçırılan) — terim, çıktıda alt dize olarak aranır.

    Alt dize araması bilinçli: "component'i" normalize edilince "component i"
    olur ve "component" içinde geçer. Türkçe ekler terimi bozmasın diye böyle.
    """
    hyp = normalize(hypothesis)
    found, missed = [], []
    for t in terms:
        (found if normalize(t) in hyp else missed).append(t)
    return found, missed
