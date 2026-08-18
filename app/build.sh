#!/bin/bash
# Katip.app paketini derler, kurar ve imzalar.
#
# Neden elle bundle: izinler (mikrofon/erişilebilirlik) TCC'de bundle id +
# imzaya bağlanıyor. Çıplak bir SPM binary'si bunları alamaz.
#
#   ./build.sh          → derle + /Applications/Katip.app'e kur
#   ./build.sh --run    → kur ve başlat
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Katip"
DEST="${KATIP_DEST:-/Applications}"
APP="$DEST/$APP_NAME.app"

echo "▶ Derleniyor (release)…"
# --disable-sandbox: SwiftPM, Package.swift'i derlerken KENDİ sandbox-exec'ini
# çağırıyor. Bu script Homebrew'un install adımı gibi ZATEN sandbox'lanmış bir
# ortamdan çalıştırılırsa iç içe sandbox_apply çağrısı "Operation not permitted"
# ile patlıyor (brew tap testinde yakalandı). Package.swift kendi dosyamız ve
# hiç plugin/exec kullanmıyor — bu sandbox'ı kapatmak risksiz.
swift build -c release --disable-sandbox

BIN=".build/release/$APP_NAME"
[ -x "$BIN" ] || { echo "✗ Binary bulunamadı: $BIN"; exit 1; }

echo "▶ Paket kuruluyor: $APP"
# Çalışan sürümü kapat, yoksa kopyalama "text file busy" verir.
pkill -x "$APP_NAME" 2>/dev/null || true
sleep 0.3

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# SPM kaynak paketleri (varsa) binary'nin yanında durmalı.
for bundle in .build/release/*.bundle; do
    [ -e "$bundle" ] || continue
    cp -R "$bundle" "$APP/Contents/MacOS/"
done

# İmza KİMLİĞİ önemli: TCC izinleri (mikrofon/erişilebilirlik) imzaya bağlanıyor.
# Ad-hoc imza her derlemede değişir → verilen izinler her seferinde düşer.
# Sabit bir geliştirici kimliğiyle imzalayınca izinler derlemeler arası korunur.
#
# `|| true` KRİTİK: kişisel bir "Apple Development" kimliği olmayan HERKESTE
# (yani gerçek dünyadaki çoğu kullanıcıda) grep eşleşme bulamayıp exit 1 verir.
# `pipefail` + `set -e` bunu üç aşamalı boru hattının genel hatası sayıp
# betiği İMZALAMADAN, HİÇBİR HATA YAZMADAN burada sessizce öldürüyordu — bu
# hatayı Homebrew paketlemesini test ederken yakaladık, ama kendi kimliğimiz
# olmayan HER doğrudan `./build.sh` kullanıcısını da vuruyordu.
SIGN_ID="${KATIP_SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -m1 "Apple Development" | awk -F'"' '{print $2}' || true)}"

if [ -n "$SIGN_ID" ]; then
    echo "▶ İmzalanıyor: $SIGN_ID"
    codesign --force --sign "$SIGN_ID" --timestamp=none "$APP" >/dev/null 2>&1 \
        || { echo "  ⚠️  kimlikle imzalanamadı, ad-hoc'a düşülüyor"; \
             codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1; }
else
    echo "▶ İmzalanıyor (ad-hoc — izinler her derlemede sıfırlanır)"
    codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1
fi

echo "✔ Kuruldu: $APP"
cat <<'EOF'

⚠️  İlk çalıştırmada:
    1. Mikrofon izni sorulacak → İzin Ver.
    2. Erişilebilirlik izni ELLE verilmeli (metnin imlece yazılması için):
       menü çubuğu ikonuna SAĞ TIK → "Erişilebilirlik izni ver…"
       İzni verdikten sonra UYGULAMAYI YENİDEN BAŞLAT.
    3. İlk açılışta model indirilir (~600 MB–1.5 GB). İkon ⬇︎ gösterirken bekle.

ℹ️  İzin sorunu yaşarsan (Ayarlar'da açık görünüyor ama çalışmıyor):
      tccutil reset Accessibility dev.mvrl.katip
    sonra uygulamayı yeniden başlat ve izni tekrar ver.
    NOT: erişilebilirlik durumu SÜREÇ BAŞINA önbelleklenir — izni verdikten
    sonra uygulamayı mutlaka kapatıp yeniden aç.
EOF

if [ "${1:-}" = "--run" ]; then
    echo "▶ Başlatılıyor…"
    open "$APP"
fi
