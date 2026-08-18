<div align="center">

<img src="docs/logo.png" width="128" alt="Katip">

# Katip

**macOS için tamamen yerel çalışan sesli dikte.**
Türkçe konuş, içine İngilizce teknik terim serpiştir — imlecin olduğu yere yazsın.

[![platform](https://img.shields.io/badge/macOS-14%2B-black)](#)
[![engine](https://img.shields.io/badge/Whisper-large--v3--turbo-blue)](#)
[![offline](https://img.shields.io/badge/100%25-offline-green)](#)
[![license](https://img.shields.io/badge/license-MIT-lightgrey)](LICENSE)

</div>

---

Amaç **vibe coding**: Claude Code / Cursor gibi ajanlara klavyeyle uzun prompt
yazmak yerine konuşarak prompt vermek.

Konuşma Türkçe, içine İngilizce teknik terimler serpiştirilmiş oluyor
("şu `component`'i `refactor` edelim"). Projenin asıl zorluğu bu **karışık dil**
durumu — hız değil.

**Neden var:** Apple'ın macOS 26 `SpeechTranscriber` API'si (30 locale) ve en hızlı
açık alternatif Parakeet TDT v3 (25 Avrupa dili) **Türkçe desteklemiyor** — ikisi de
bu makinede ölçülerek doğrulandı. Türkçe+İngilizce karışık dikte için Whisper
pratikte tek makul seçenek.

- 🎤 Menü çubuğu ikonu · atanabilir global kısayol · bas-tut ve çift-bas-kilit
- 〰️ Masaüstünde yüzen kapsül: canlı ses dalgası, kenara yapışma, açık/koyu tema
- 🔒 Kilit modunda **akan metin** — cümle aralarından bölüp yazar
- 📴 Bulut yok, abonelik yok, ses cihazdan çıkmıyor
- ⚡ ~1.75 sn / dikte (M1 Pro, Metal)

## Durum

| Faz | Durum |
|---|---|
| **Adım 1** — menü çubuğu uygulaması, tıkla-konuş-yaz | ✅ **çalışıyor** (`app/`) |
| **Adım 2** — atanabilir kısayol (bas-tut + çift-bas-kilit) | ✅ **çalışıyor** |
| **Adım 3** — yüzen kart (canlı ses dalgaları) | ✅ **çalışıyor** |
| **Adım 4** — VAD parçalama (kilit modunda akan metin) | ✅ **çalışıyor** |
| **Adım 5** — geçmiş + girişte başlat | ✅ **çalışıyor** |
| Adım 6 — uygulama-bazlı kurallar, notarization | ⬜ |
| P0 — kalite tezgâhı (faster-whisper, Python) | 🅿️ rafta (`p0-bench/`) |

## Kurulum

```bash
cd app && ./build.sh --run
```

`Katip.app` derlenir, `/Applications`'a kurulur ve başlar. Menü çubuğunda 🎤
ikonu belirir.

**Kullanım — üç yol, hepsi aynı durum makinesine bağlı:**

| Jest | Ne olur |
|---|---|
| İkona **sol tık** | Dinlemeye başlar · tekrar tık → yazıya çevirir |
| Kısayola **basılı tut** | Bas-konuş — konuşurken metin cümle cümle akar |
| Kısayola **çift bas** | 🔒 Kilit modu: elini çek, sürekli dinler · tuşa bas → bitir |
| İkona **sağ tık** | Menü (kısayol seçimi, sözlük, düzeltme tablosu, çıkış) |

**Kısayol tuşu menüden seçilir:** sağ tık → "Kısayol tuşu" → Sağ Option/Command/
Control/Shift veya F13–F19 veya Kapalı. Varsayılan **Sağ Option**.
Fn/🌐 listede yok: macOS'un kendi katip kısayolu onu sistem seviyesinde kapıyor.

Kayıt ilk basışta **hemen** başlar; bas-tut ile çift-bas ayrımı bırakışta yapılır
(250 ms / 400 ms eşikleri) — beklemek ilk hecenin kaybı olurdu.

**Yüzen kapsül:** masaüstünde duran, sürüklenebilir bir gösterge (Wispr Flow'un
"Flow Bar"ı gibi). **Boştayken dar (84×32), konuşurken genişler (148×32)** —
merkezi sabit tutup iki yana açılıyor.

İçinde solda **durum ikonu**, sağda **ses dalgası** var:

| Durum | İkon | Renk |
|---|---|---|
| Model yükleniyor | ⬇︎ | soluk gri |
| Hazır | 🎤 | ikincil gri |
| Kayıt | 🎤 | kırmızı |
| Kilit modu | 🔒 | turuncu |
| Çeviri | 〰️ | mavi (ilerleyen dalga) |
| Hata | ⚠️ | sarı |

**Kenara yapışma:** kapsülü bir kenara 140 px'den yakın bırakırsan o kenara
yapışır (14 px boşlukla, 0.16 sn animasyonla). Dört kenar da destekleniyor.
Konum hatırlanıyor.

**Açık/koyu tema:** `.popover` malzemesi ve semantik renkler (`separatorColor`,
`secondaryLabelColor`) kullanılıyor → her iki temada doğru kontrast. Tema
değişince otomatik yeniden çiziliyor. (`.hudWindow` her zaman koyu kalıyordu.)

Karta tıklamak menü çubuğu ikonuyla aynı işi yapıyor; kısayol yapısı aynen
geçerli. Menüden kapatılabilir: sağ tık → "Yüzen kart".

> Kapsül **non-activating** bir `NSPanel`: göründüğünde, sürüklendiğinde veya
> tıklandığında odağı ÇALMAZ. Bu şart — aksi hâlde yazdığın uygulamanın imleç
> konumu kaybolur ve metin yanlış yere gider.
>
> **Boştaki çubuklar hareket etmiyor** (soluk ve sabit duruyorlar). Sürekli
> animasyon boşta **%9 CPU** yakıyordu (ölçüldü); hareket sadece iş varken →
> boşta yine **%0 CPU**.

**Animasyonlar:** dinlerken ikon **canlı mikrofon seviyesiyle dalgalanır**
(kayıtta kırmızı, kilit modunda turuncu), çeviri sırasında native yükleniyor
topacı döner. Seviye animasyonu sadece "açık" demiyor — mikrofonun seni gerçekten
duyduğunu gösteriyor.

### İlk çalıştırma — ÜÇ ayrı izin gerekiyor

| İzin | Olmazsa ne olur |
|---|---|
| **Mikrofon** | Ses yakalanmaz |
| **Erişilebilirlik** | Çeviri olur ama metin imlece yazılamaz |
| **Giriş İzleme** | Kısayol tuşu hiç çalışmaz (olaylar uygulamaya ulaşmaz) |

Erişilebilirlik ve Giriş İzleme **ayrı izinlerdir, biri diğerinin yerine geçmez.**
Menüde ikisinin durumu da görünür. Her ikisi de **süreç başına önbelleklenir** →
izni verkatipn sonra uygulamayı kapatıp yeniden aç.

> ⚠️ **"Ayarlar'da açık ama çalışmıyor" durumu:** izin bir kez *reddedilmiş*
> duruma düşerse macOS sistem istem penceresini bir daha göstermez ve uygulama
> ne yaparsan yap "izin yok" görür. Çözüm kaydı sıfırlamak:
> ```bash
> tccutil reset ListenEvent dev.mvrl.katip      # kısayol çalışmıyorsa
> tccutil reset Accessibility dev.mvrl.katip    # metin yazılmıyorsa
> ```
> sonra uygulamayı yeniden başlat. Log "REDDEDİLMİŞ" ile "henüz sorulmadı"
> ayrımını yazar — ikisi de "izin yok" görünür ama çözümleri farklıdır.
Model indirilir (~1.6 GB). İkon ⬇︎ iken bekle. Sonraki açılışlar ~10 saniye.

Durumu izlemek için: `tail -f ~/Library/Application\ Support/Katip/katip.log`

## Akan metin (VAD parçalama)

Konuşma **cümle aralarındaki sessizlikten** bölünüyor; her parça ayrı çevrilip
imlece yazılıyor. **Hem bas-tut hem kilit modunda** çalışır — uzun konuşmada
metin akarak gelir, sonda toplu bekleme olmaz.

Neden önemli: ölçülen gerçek dikte süresi ortalama **71 saniye** (vibe coding'de
uzun prompt söyleniyor). Akış olmadan bitişte ~13 saniye bekleniyordu; akışla
bekleme son cümleye iniyor.

Kısa diktede davranış değişmez — VAD kesmek için ≥0.6 sn konuşma + ≥0.45 sn
sessizlik ister, tek cümle bölünmez.

| Ayar | Değer | Ne yapar |
|---|---|---|
| `speechPeak` | 0.03 | Bunun üstü konuşma sayılır (ölçüm: konuşma ~0.38, sessizlik 0.004–0.006) |
| `minSilence` | 0.45 sn | Bu kadar sessizlik = cümle bitti, parçala |
| `minSpeech` | 0.6 sn | Bundan kısa parçayı gönderme |
| `tailPadding` | 0.15 sn | Kesime biraz sessizlik ekle (kelime kırpılmasın) |

`Sources/Katip/SpeechSegmenter.swift`. Gürültülü ortamda kesme olmuyorsa
`speechPeak` yükseltilmeli.

**Mikrofon olmadan test:**
```bash
Katip.app/Contents/MacOS/Katip --vadtest ses.wav
```
Kesim noktalarını yazdırır. VAD ayrı bir tipte olmasının sebebi bu — konuşmadan
doğrulanabiliyor.

> Son cümleden sonra yeterli sessizlik yoksa o parça **artık** olarak bekler ve
> kilit modunu bitirdiğinde gönderilir. Kayıp yok.

## Geçmiş

Sağ tık → **Geçmiş…** (veya `H`). Aranabilir liste: her kayıtta metin, ne kadar
önce, hangi uygulamaya yazıldığı ve kaç saniyelik konuşma olduğu görünür.
Tıklayınca kopyalanır.

Arama Türkçe'ye duyarlı (`i/İ` ve aksan farkları eşleşir).

**Saklama: 30 gün.** Daha eski kayıtlar açılışta ve her yeni diktede otomatik
siliniyor, dosya yeniden yazılıyor. Ayrıca en fazla 1000 kayıt tutuluyor.

> ⚠️ Konuştuğun her şey `~/Library/Application Support/Katip/history.jsonl`
> içinde **düz metin** olarak durur. 30 gün otomatik temizlik gizlilik için var
> ama yeterli değil: şifre veya mahrem bir şey dikte edersen menüdeki
> "Geçmişi temizle" ile hemen sil. JSON Lines olduğu için `grep`'lenebilir de.

Süreyi değiştirmek için `History.retentionDays`.

## Girişte başlat

Sağ tık → **Girişte başlat**. `SMAppService` kullanıyor (macOS 13+); eski
LaunchAgent plist yazma yöntemine gerek yok. macOS onay isterse menüde
"(Ayarlar'dan onayla)" yazar → Sistem Ayarları > Genel > Giriş Öğeleri.

## Ayarlar (düz metin dosyaları)

`~/Library/Application Support/Katip/`

| Dosya | Ne işe yarar |
|---|---|
| `glossary.txt` | Whisper'a terim ipucu. **Bütçe 111 token**, aşarsa BAŞTAKİLER düşer → kritik terimleri sona yaz. |
| `replacements.txt` | `yanlış = doğru` kural tablosu. Sözlüğün kurtaramadığı yerde devreye girer. |
| `katip.log` | Ne olduğunu gösterir (model, sözlük token sayısı, hatalar). |

Değişiklikten sonra uygulamayı yeniden başlat.

## Hız

Ölçüm: M1 Pro, GPU (Metal), `large-v3-turbo`, TTS örnekleri, 3 tur ortalaması.

| | önce | sonra |
|---|---|---|
| kısa cümle (1.9 sn ses) | 4.00 sn | **1.75 sn** |
| uzun cümle (6.3 sn ses) | 4.52 sn | **2.22 sn** |
| ilk katip (açılıştan sonra) | ~8 sn | **1.75 sn** |

Üç değişiklik:

**1. Sözlük yönlendirmesi varsayılan KAPALI — ~2.3 saniye kazandırdı.**
109 prompt token'ı decoder bağlamına ekleniyor ve her katipde ~2.3 sn'ye mal
oluyordu; toplam gecikmenin yarısından fazlası. Test cümlelerinde çıktıya katkısı
ölçülemedi (uzun cümlede sonuç sözlüklü ve sözlüksüz **birebir aynı**).
Menüden açılabilir: sağ tık → "Sözlük yönlendirmesi (~2 sn yavaşlatır)".

> Bu, mimarideki katman sıralamasını tersine çevirdi: terminoloji için
> **`replacements.txt` (0 ms, deterministik) prompt yönlendirmesinden kesinlikle
> daha iyi bir takas.** Sözlük ancak gerçekten fark yarattığını görürsen açılmalı.

**2. Kendi ısınma turumuz — ilk katip cezasını kaldırdı.**
İlk çeviri 4.9 sn, sonrakiler 1.75 sn. WhisperKit'in `prewarm` seçeneği bunu
**kapsamıyor** (ölçüldü: açıkken de ilk tur 4.9 sn, üstelik yüklemeye 2 sn ekliyor).
Açılışta sahte bir çeviri koşturuyoruz. Dikkat: **sessizlikle olmuyor** —
no-speech kapısı çözümlemeyi kısa devre ediyor ve ısınma 0.0 sn sürüyor.
3 saniyelik gürültü + `noSpeechThreshold: nil` gerekiyor.

**3. Model seçimi doğrulandı.** `large-v3` 626MB varyantı turbo'dan **daha yavaş**
(3.18 sn vs 2.22 sn) — sıkıştırılmış ama decoder katmanları tam. `small` 1.35 sn
ama Türkçe kalitesi düşüyor (`chat` → `çat`). Turbo en iyi denge.

Kalan hedef: 700 ms. Oraya ulaşmanın yolu ANE — ve ANE derlemesi bu makinede
tıkanıyor (aşağıda).

## Uygulama yazılırken çıkan bulgular

**ANE derlemesi bu makinede patinaj yapıyor.** `large-v3-turbo`'yu Neural
Engine'e vermek `ANECompilerService`'i **25+ dakika %100 CPU'da** tuttu, derleme
önbelleği hiç büyümedi, model hiç yüklenmedi. Metal (GPU) yolunda aynı model
**33 saniyede** yüklendi (önbellekten ~9 sn). Varsayılan artık GPU.
ANE'yi tekrar denemek için: `KATIP_ANE=1 open -a Katip`.
Araştırmadaki "ANE ~20x real-time, ~1 W" hedefi bu yüzden şimdilik geçerli değil
— Metal ~9x real-time, katip için fazlasıyla yeterli.

**Prompt bütçesi 224 değil, 111.** WhisperKit `maxPromptLen = maxTokenContext/2 - 1`
kullanıyor ve `maxTokenContext = 224`. İlk sözlüğüm 206 token'dı, yarısı sessizce
kırpılıyordu. Uygulama artık açılışta gerçek token sayısını log'a yazıyor.

**WhisperKit modeli varsayılan olarak `~/Documents/huggingface`'e indiriyor** —
1.6 GB Belgeler klasörüne. `downloadBase` ile Application Support'a alındı.

**NSLog, ad-hoc imzalı menü çubuğu uygulamasında unified log'a düşmüyor.**
Teşhis için dosya günlüğü (`Trace`) şart oldu.

## Neden iki farklı motor?

**Ölçüm tezgâhı ile ürün motoru aynı olmak zorunda değil.**

- **P0 → faster-whisper (Python, CPU).** API'si en zengini (`hotwords`,
  `multilingual`, gömülü Silero VAD) ve Python iterasyonu Swift'ten kat kat hızlı.
  P0'ın işi kod yazmak değil **ölçmek**, o yüzden CPU-only olması sorun değil.
- **P1+ → WhisperKit (Swift, ANE).** CTranslate2'nin Metal/ANE backend'i yok —
  bu makinede doğrulandı:
  ```
  ctranslate2.get_supported_compute_types("metal")
  → ValueError: unsupported device metal
  ```
  Ürün motoru ANE'de koşmalı: ~1 W, ~20x+ real-time.

Aktarım güvenli çünkü `hotwords` ayrı bir mekanizma değil — prompt'un (`sot_prev`)
şekerlemesi ve aynı ~224 token bütçesine tabi. **Tezgâhta bulunan terim listesi
WhisperKit'in `promptTokens`'ına birebir geçiyor.** Taşınmayan tek şey mutlak WER
sayıları (CT2 INT8 ile CoreML kuantizasyonu farklı) — onlar P1'de yeniden doğrulanır.

## P0: kalite tezgâhı

`p0-bench/` — dört konfigürasyonu **aynı ses dosyaları üzerinde** yan yana koşturur:

| Konfigürasyon | Ne test ediyor |
|---|---|
| `auto` | Dil otomatik algılansın → pencere `en`'e kayıyor mu? |
| `tr` | Dil `tr`'ye sabit → Türkçe morfoloji düzeliyor mu? |
| `tr+hotwords` | + teknik sözlük → terimler İngilizce yazımıyla korunuyor mu? |
| `multilingual` | Segment başına dil algılama → işe yarıyor mu? |

### Çalıştır

```bash
cd p0-bench
./.venv/bin/python record.py    # cümleleri kaydet (~10 dk)
./.venv/bin/python bench.py     # dört konfigürasyonu ölç
```

İlk `bench.py` çalıştırması modeli indirir (~1.5 GB, birkaç dakika). Sonraki
çalıştırmalar önbellekten yükler.

Sonuçlar `p0-bench/results/<tarih>.md` ve `.json` olarak yazılır.
Örnek çıktı formatı: `results/ORNEK-duman-testi-tts.md`.

### Ölçtüğümüz şey ham WER değil

Asıl metrik **terim korunumu**: Türkçe cümlenin içindeki İngilizce teknik
terimler İngilizce yazımıyla mı çıkıyor? WER ikincil — Türkçe morfolojinin
bozulup bozulmadığını gösteriyor.

Ayrıca her koşuda **sessizlik kaydı** da çevriliyor: Whisper Türkçe'de sessizlik
üzerine uydurma altyazı üretmeye eğilimli ("Altyazı M.K." tipi artefaktlar).
Çıktı boş değilse halüsinasyon var demektir.

### Çıkış kriteri

P0 bir ısınma turu değil, **kalite kapısı**. Tüm proje "Whisper karışık
konuşmamı yeterince iyi çeviriyor" varsayımına dayanıyor. Kalite yetersizse plan
değişir (`large-v3` → gerekirse Türkçe fine-tune). Bunu P4'te değil P0'da
öğrenmek istiyoruz.

## Kendi cümlelerini yaz

`p0-bench/sentences.txt` başlangıç seti — 20 genel yazılım cümlesi. **Kendi
konuşma tarzına göre değiştir.** Tezgâhın değeri cümlelerin senin gerçek
konuşmana benzemesinden geliyor; başkasının cümleleriyle ölçülen kalite seni
bağlamaz.

İngilizce terimleri `` `backtick` `` içine al — hem referans metin hem beklenen
terim listesi bundan türetiliyor.

`p0-bench/glossary.txt` ise `hotwords`'e beslenen sözlük. Bütçe ~224 token,
`bench.py` çalışırken gerçek sayıyı yazdırıyor.

> ⚠️ **Kritik terimleri BAŞA yaz** — sezgiye ters ama faster-whisper bütçe
> aşımında `hotwords_tokens[:N]` ile **sondan** kırpıyor.
> WhisperKit ve openai/whisper tam tersi (`suffix`/`[-N:]`, sondan tutuyor).
> P1'de sözlüğü WhisperKit'e taşırken **listeyi ters çevir.**

## Gereksinimler

- macOS 26+, Apple Silicon
- Python 3.9+ (venv `p0-bench/.venv` içinde kurulu)
- `ffmpeg` (kayıt için — `brew install ffmpeg`)
- P1'den itibaren: Xcode 26+
