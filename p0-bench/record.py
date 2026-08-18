#!/usr/bin/env python3
"""sentences.txt'teki cümleleri sırayla kaydeder (ffmpeg + avfoundation).

    python record.py                # eksik olanları kaydet
    python record.py --only 03 07   # sadece bu cümleleri (yeniden) kaydet
    python record.py --all          # hepsini baştan kaydet
    python record.py --devices      # ses giriş cihazlarını listele

Kayıt: 16 kHz mono WAV — Whisper'ın beklediği format, dönüştürme gerekmiyor.
Alternatif: kaydı başka bir araçla yapıp audio/01.wav ... audio/20.wav ve
audio/silence.wav olarak koyabilirsin; bench.py sadece dosyalara bakıyor.
"""

import argparse
import re
import subprocess
import sys

from corpus import AUDIO, SILENCE_ID, load_sentences

SILENCE_SECONDS = 8


# Sanal/uygulama ses cihazları — bunlar mikrofon değil, kayıt buradan yapılmamalı.
VIRTUAL = ("teams", "zoom", "blackhole", "soundflower", "loopback", "aggregate",
           "krisp", "voicemeeter", "obs")


def audio_devices():
    """[(index, ad)] — ffmpeg'in avfoundation cihaz listesinden ses girişleri."""
    p = subprocess.run(
        ["ffmpeg", "-hide_banner", "-f", "avfoundation", "-list_devices", "true", "-i", ""],
        capture_output=True, text=True,
    )
    devices, in_audio = [], False
    for line in p.stderr.splitlines():
        if "AVFoundation audio devices" in line:
            in_audio = True
            continue
        if "AVFoundation video devices" in line:
            in_audio = False
            continue
        m = re.search(r"\[(\d+)\]\s+(.+?)\s*$", line)
        if in_audio and m:
            devices.append((m.group(1), m.group(2)))
    return devices


def pick_device():
    """Gerçek mikrofonu otomatik seç.

    İndeks 0 genelde mikrofon DEĞİL — bu makinede 0 = "Microsoft Teams Audio".
    Sanal cihazlardan kayıt sessiz WAV üretir, o yüzden ada bakarak seçiyoruz.
    """
    devices = audio_devices()
    if not devices:
        return "0", None
    real = [(i, n) for i, n in devices if not any(v in n.lower() for v in VIRTUAL)]
    for idx, name in real:
        if "mikrofon" in name.lower() or "microphone" in name.lower():
            return idx, name
    if real:
        return real[0][0], real[0][1]
    return devices[0][0], devices[0][1]


def list_devices():
    print("Ses giriş cihazları:\n")
    chosen, _ = pick_device()
    for idx, name in audio_devices():
        mark = "  ← otomatik seçilen" if idx == chosen else ""
        flag = " (sanal)" if any(v in name.lower() for v in VIRTUAL) else ""
        print(f"  [{idx}] {name}{flag}{mark}")
    print("\nBaşkasını kullanmak için:  python record.py --device N")


def record(path, device, seconds=None):
    """seconds verilirse o kadar kaydeder, yoksa Enter'a basılana kadar."""
    cmd = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
           "-f", "avfoundation", "-i", f":{device}",
           "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le"]
    if seconds:
        cmd += ["-t", str(seconds)]
    cmd.append(str(path))

    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE)
    try:
        if seconds:
            proc.wait()
        else:
            input()
            proc.communicate(b"q", timeout=5)
    except KeyboardInterrupt:
        proc.terminate()
        raise
    finally:
        if proc.poll() is None:
            proc.terminate()
            proc.wait(timeout=5)

    if not path.exists() or path.stat().st_size < 1000:
        print(f"  ⚠️  {path.name} boş/çok küçük görünüyor — mikrofon izni verildi mi?")
        return False
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", nargs="+", metavar="ID")
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--devices", action="store_true")
    ap.add_argument("--device", help="avfoundation ses cihaz indeksi (vars. otomatik)")
    args = ap.parse_args()

    if args.devices:
        list_devices()
        return

    if args.device:
        device, name = args.device, None
    else:
        device, name = pick_device()
    print(f"\n🎙  Kayıt cihazı: [{device}] {name or '(bilinmiyor)'}")
    print("   Yanlışsa:  python record.py --devices")

    AUDIO.mkdir(exist_ok=True)
    items = load_sentences()

    todo = items
    if args.only:
        todo = [s for s in items if s["id"] in args.only]
    elif not args.all:
        todo = [s for s in items if not (AUDIO / f"{s['id']}.wav").exists()]

    if not todo and not args.only:
        print("Tüm cümleler zaten kayıtlı. Yeniden kaydetmek için --all veya --only.")
    else:
        print(f"\n{len(todo)} cümle kaydedilecek. Her cümlede:")
        print("  Enter → kayıt başlar · konuş · Enter → kayıt biter\n")
        print("Doğal konuş. Cümleyi ezberden okuma, normal konuştuğun hızda söyle.\n")

        for n, s in enumerate(todo, start=1):
            path = AUDIO / f"{s['id']}.wav"
            print(f"[{n}/{len(todo)}] #{s['id']}  →  {s['reference']}")
            input("      Enter ile başlat...")
            print("      🔴 KAYITTA — bitince Enter")
            record(path, device)
            print(f"      ✔ {path.name}\n")

    silence = AUDIO / f"{SILENCE_ID}.wav"
    if args.all or not silence.exists():
        print(f"Son adım: {SILENCE_SECONDS} saniye SESSİZLİK kaydı (halüsinasyon testi).")
        print("Hiçbir şey söyleme, normal ortam sesinde bekle.")
        input("      Enter ile başlat...")
        print(f"      🔴 KAYITTA ({SILENCE_SECONDS} sn)...")
        record(silence, device, seconds=SILENCE_SECONDS)
        print(f"      ✔ {silence.name}\n")

    print("Hazır. Şimdi:  python bench.py")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\nİptal edildi.")
        sys.exit(130)
