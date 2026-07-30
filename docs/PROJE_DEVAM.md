# oto_deri_kalip — Proje Devam Notu

Bu dosya, projeyi yeni bir sohbette kaldığı yerden sürdürmek için yazıldı.
Amaç: sıfırdan yeniden keşfedilmesi gereken hiçbir karar bırakmamak.

**Repo:** https://github.com/Kapsew/oto_deri_kalip
**Durum:** 374 test geçiyor · ~11.700 satır TS · Vercel'de yayında
**Son tamamlanan adım:** 16 (süre katsayıları ayarlanabilir)

---

## 1. Ürün ne yapıyor

El yapımı deri ürünler (kartlık, cüzdan, çanta) için **ölçülü, dikiş izli,
A4'e 1:1 basılabilir kalıp** üretiyor. Kullanıcı parametreleri arayüzden
ayarlıyor, PDF indiriyor, basıp kesiyor.

**Hedef kitle: A4'e basıp ELLE kesen hobiciler.** Bu karar tüm mimariyi
belirliyor — baskı sadakati, lazer hassasiyetinden önce gelir.

---

## 2. Pazarlık konusu olmayan mimari kurallar

1. **`packages/geometry` ve `packages/patterns` saf kalır.** React, DOM,
   `fs`, `window` — hiçbiri import edilmez. Aynı kodun tarayıcıda, Node'da
   ve ileride Capacitor'da çalışması buna bağlı.
2. **Motorun içinde her uzunluk milimetredir** (`Mm` tipi). Point, inch,
   piksel yalnızca çıktı katmanında görülür. Birim dönüşümü tek yerde:
   `mmToPt`, pdf-lib sınırında.
3. **Kalıp bir "şekil" değil, bir "kesit çözümüdür."** Dış hatlar elle
   çizilmez; katman yığınından hesaplanır.
4. **`packages/print` font baytlarını dışarıdan alır.** Dosya sistemi ya
   da tarayıcı API'si kullanmaz.

---

## 3. Çalışma yöntemi (bunu koru)

Kullanıcı değişiklikleri **`.sh` script olarak** alıyor — repo kendi
makinesinde, ben doğrudan yazamıyorum.

Her script:
- Repo kökünde çalışacak şekilde yazılır, kök kontrolü yapar
- Idempotent (tekrar çalıştırmak sorun çıkarmaz)
- Dosyaları `cat > path << 'DELIM'` ile yazar
- Sonunda `pnpm test`, `pnpm typecheck`, `pnpm --filter @odk/web build`
- Sonunda git komutlarını ve commit mesajını basar

**Script'i üretmeden önce mutlaka temiz bir kopyada baştan sona
çalıştırıp doğrula.** Bu yöntem şimdiye kadar birkaç kırık script'i
kullanıcıya gitmeden yakaladı.

Kullanıcıya her yanıtta **bash + git komutları** verilir.

Numaralandırma 02'den 16'ya geldi; sıradaki `17_*.sh`.

---

## 4. Paket yapısı

```
packages/geometry/   saf geometri — birim, vektör, path, yay uzunluğu,
                     offset/boolean (clipper-lib), köşe yuvarlatma,
                     dikiş dağıtıcı
packages/patterns/   malzeme modeli, kesit çözücü, modüller, üreticiler,
                     katalog, talimatlar, maliyet
packages/print/      A4 sayfa yerleşimi, döşeme, PDF üretimi
apps/web/            React + Vite arayüz
```

### Önemli dosyalar
| Dosya | İçerik |
|---|---|
| `geometry/src/units.ts` | `Mm`, `EPS=1µm`, mm↔pt, ISO ID-1, iron adımları |
| `geometry/src/path/arclength.ts` | `pointAtDistance`, köşe tespiti, span bölme |
| `geometry/src/clip/clipper.ts` | offset, boolean, `offsetSingle` (hata atar) |
| `geometry/src/clip/allowance.ts` | kalem payı, dikiş hattı, `narrowestWidth` |
| `geometry/src/stitch/distribute.ts` | delik dağıtımı, `selectPitch` minimax+bant |
| `patterns/src/crosssection.ts` | **motorun kalbi** — nötr eksen yürümesi |
| `patterns/src/stitchprojection.ts` | ana plandan parçalara delik yansıtma |
| `patterns/src/{cardholder,bifold,tote}.ts` | üç ürün ailesi |
| `patterns/src/costing.ts` | alan + süre hesabı, fiyat zinciri |
| `print/src/layout.ts` | sayfa bazlı yerleştirme + 90° döndürme |
| `print/src/pdf.ts` | kapak, montaj, adımlar, desen sayfaları |
| `docs/SOURCES.md` | **her sabitin dayanağı** — BELGELENMİŞ / TÜRETİLMİŞ / GEÇİCİ |

---

## 5. Neler çalışıyor

### Üç ürün ailesi (katalogda `status: "hazir"`)
- **Katlanır kartlık** — dikey kat, U dikiş, T-slot yuvalar
- **Bifold cüzdan** — banknot bölmesi, iki panelde kart yuvaları,
  hedef kapalı ölçü modu
- **Körüklü çanta** — dolanan körük (tek/üç parça), askı seçenekleri

`availableFamilies()` yalnızca gerçekten üretilebilenleri döndürür ve
bunu bir test koruyor. Listeye "hazır" bir aile eklemek, jeneratörünü de
eklemiş olmayı gerektirir.

### PDF çıktısı
kapak → montaj → yapım adımları → desen sayfaları

- 50mm kalibrasyon karesi + ölçek düzeltme döngüsü
- Parçalar 90° döndürülerek tek sayfaya sığdırılır (hizalama gerekmez)
- Sığmayanlar döşemeye düşer (10mm bindirme, köşe haçları, sayfa kodları)
- Çizgiler renkle değil desenle ayrışır (siyah-beyaz yazıcı için)
- Talimatlar kalıptan türetilir, sabit metin değil
- Türkçe karakterler için gömülü font

### Maliyet
Motor **alanı ve süreyi** hesaplar (kalıbı kendi üretti), **fiyatları**
kullanıcıdan alır. Hız katsayısı ve elle süre girişi mevcut.

---

## 6. Doğrulama çapaları (modelin sağlaması)

Bu üç şey, modelin doğru terimi yakaladığının bağımsız kanıtı. Testlerde
sabitlendi; kırılırlarsa model bozulmuş demektir.

**1. Yarım inç kuralı.** MAKESUPPLY: bifold'un dış kabuğu iç kabuktan
~12.7mm uzun olmalı. Model 2 yuva/panel için **11.8mm** veriyor (0.9mm
sapma). Formül: `Δ = θ × aralık`, 180° katta `π × 4mm ≈ 12.57mm`.

**2. Bölme genişliği.** Borderland Leather: yatay kart bölmesi ~100mm.
Model **100.0mm** veriyor.

**3. Açık bifold ölçüsü.** Ticari billfold kalıbı açık 215mm. Model 2+2
için **213.6mm** veriyor.

---

## 7. Karşı sezgisel kararlar — bunları değiştirmeden önce oku

**Kalem payı İÇE uygulanır.** Kullanıcı çizgi izinin dışından keser ve
kalem ucu dışa kaçar; ikisi parçayı büyütür. Şablonu o kadar küçük
basarak nominal ölçüde buluşuruz.

**Köşe yuvarlatma NOMİNAL şekle uygulanır, dikiş hattına değil.** Deri
parçanın köşesi yuvarlak kesilir, dikiş hattı onu takip eder. İçe öteleme
dışbükey köşeleri yuvarlamaz — bu geometrik olarak doğrudur, offset'in
yan ürünü olarak beklenemez.

**Adım seçimi kullanıcıya aittir.** Otomatik seçim yalnızca sapmayı
ölçebilir; dikişin sıklığı estetik bir karardır. Varsayılan 3.85mm.

**Delikler ana plandan yansıtılır, parça başına hesaplanmaz.** Hesaplansa
katmanlar üst üste konduğunda tutmaz. Bu yüzden aynı tip parçanın farklı
örnekleri **gruplanamaz** (sol/sağ panel farklı kenarlardan delik alır).

**Dikiş hattı U şeklinde, üst kenar AÇIK.** Cüzdanda banknot/kart
bölmesinin ağzı; dikilirse ürün işe yaramaz.

**Döşeme yerine döndürme.** Hizalama hatası doğrudan ürünün ölçüsüne
girer. Parça 90° çevrilerek sığdırılır; döşeme yalnızca son çare.

**Uzun düz şeritler basılmaz.** 134cm askı için 5 sayfa döşeme kâğıt
israfı; ölçüsü bildirilir, cetvelle kesilir (`STRIP_TEMPLATE_LIMIT` 400mm).

**Kenar bitirme cüzdanda dikişten ÖNCE, çantada SONRA.** Cüzdanda iplik
boyanır ve zımpara aşındırır; çantada kenar katmanlardan oluşur ve
dikilmeden hizalanamaz.

---

## 8. Yapılmış ve düzeltilmiş hatalar — tekrarlanmasın

| Hata | Belirti | Düzeltme |
|---|---|---|
| `clipper2-js` offset'i bozuk | 100×50 +2mm → alan 5616 yerine 5302 | `clipper-lib@6.4.2` kullanılıyor |
| IBM Plex Mono + fontkit | **boşluk** karakterinde patlıyor | JetBrains Mono (test ile sabitlendi) |
| `narrowestWidth` kopmayı görmüyordu | 2mm boyun 17mm ölçülüyordu | ölçüt "tek dış kontur kaldı mı" |
| `selectPitch` dejenere | 559mm çevrede 2.7mm seçiyordu (207 delik) | 0.05mm tolerans bandı + en büyük adım |
| Etiket kırpılıyordu | en üstteki parçanın adı kayboluyordu | yerleşimde 8mm `LABEL_SPACE` |
| İç kabuk ortalanmıştı | 143 yerine 105 delik | kat payı sırtta soğurulur, kenarlar hizalı |
| Kapalı çevre dikişi | bölme ağzı dikiliyordu | U hattı, üst kenar açık |
| Kartlık kat payı 121mm | "dış − iç" farklı run'lardan | kat payı = düz uzunluk − 2×panel |
| Dikiş süresi 5.16 sa | parça başına delikler toplanıyordu | `stitchedHoles`: iplik katmanlardan **bir kerede** geçer |
| A4 uyarısı yanlış | döndürme hesaba katılmıyordu | `fitsOnA4` döndürmeyi de dener |
| TIGHT_RADIUS hep yanlış | yığın kalınlığına bakıyordu | en iç katmanın kalınlığı |
| BULKY 3 yuvada tetikleniyordu | yüklü kalınlığa bakıyordu | belgelenmiş 6–8mm hedefi **boş** ürün için |

Ayrıca **yanlış teşhis koyduğum bir vaka:** "yan dikiş katı keser" demiştim,
yanlıştı — taco katlamada yan dikiş kat köşesini dönerek geçer. Doğru
sonuca yanlış gerekçeyle varmıştım; düzeltildi.

---

## 9. ⚠ GEÇİCİ değerler — fiziksel testle kalibre edilmeli

`docs/SOURCES.md` bunları BELGELENMİŞ / TÜRETİLMİŞ / GEÇİCİ olarak ayırır.
Bu ayrımı koru — altı ay sonra hangi sayıya güvenilebileceğini bilmenin
başka yolu yok.

| Değer | Şimdiki | Not |
|---|---|---|
| k-faktörü | 0.38–0.45 | Deri için ölçülmüş veri YOK; sac metal bandından |
| Kademe (reveal) | 12mm | Belgelenen tek sayı 5mm alt sınırı |
| Tıraşlama oranı | 0.5 | Sayısal veri bulunamadı |
| Dikiş hızı | 50 delik/sa | Tek dayanak "bifold için 2–4 saat dikiş" |
| Fire katsayısı | 1.35 | Küçük deri işlerinde %25–40 tipik |
| EUR/GBP banknot | 153×77 / 146×77 | `verified: false`, uyarı üretiyor |

**Önemli:** k-faktörü ikincil terim. 1.2mm deride 0.38↔0.45 belirsizliği
0.26mm etki yapar; katman öteleme terimi 48 kat daha büyük. Yani k'yı
yanlış tahmin etmek kalıbı bozmuyor. Bu iddia teste sabitlendi.

---

## 10. Fiziksel test — bir sonraki gerçek adım

Henüz **hiçbir kalıp kesilip dikilmedi.** Bu, projedeki en büyük açık risk.

**Önerilen test:** bifold 2+2 (en az malzeme, yarım inç kuralına en yakın
yapılandırma).

Ölçülecekler:
1. 50mm kalibrasyon karesinin gerçek ölçüsü
2. Dış kabuk ile iç kabuk arasındaki gerçek uzunluk farkı (model: 11.83mm)
3. Kapalı kalınlık (model: 6.20mm) ve kart yüklü (9.24mm)
4. Kesim / delme / dikiş / kenar sürelerini ayrı ayrı kronometreyle

Bu dört ölçümle yukarıdaki geçici satırların çoğu gerçek veriyle
değiştirilebilir.

---

## 11. Açık işler

**Sarf malzemesi modeli zayıf.** Şu an `süre × saatlik oran` ile
hesaplanıyor. Ama sarf süreyle değil miktarla tükenir: iplik dikiş
uzunluğuna, kenar boyası kenar uzunluğuna, tutkal alana bağlı. Yavaş
çalışan daha çok iplik harcamış sayılıyor — yanlış. Motor doğru sayıları
zaten biliyor. Önerilen model:
```
iplik  = dikiş uzunluğu × 3.5 × TL/m
boya   = kenar uzunluğu × TL/m
tutkal = yapıştırma alanı × TL/dm²
sabit  = iğne/zımpara aşınması
```
Kullanıcı "şimdilik yeterli" dedi; sarf toplam maliyetin ~%6'sı.

**Katalogda planlanan aileler:** düz kart kılıfı, uzun cüzdan (fermuarlı
bozuk para gözü), kemer, anahtarlık kılıfı.

**Modül sistemi (Faz 3'ün tamamı).** Şu an her aile kendi jeneratörünü
yazıyor ve kod tekrarı var (rectangle, tSlotShape, roundCorners sırası üç
yerde). `CardSlot`, `BillPocket`, `Gusset` gerçek birleştirilebilir
modüllere dönüştürülmeli. `PatternFamily.modules` alanı bunun için hazır
ama şu an sadece etiket.

**Faz 7 — istatistik/varyasyon.** Kullanım verisi biriktikçe parametre
zarfı örnekleme. En az 100–200 gerçek kullanım gerekiyor. ML değil.

**Kalıp kütüphanesi ve lisans.** Faz 4'te planlanmıştı. ⚠ İnternetteki
bedava kalıpların çoğu "kişisel kullanım" lisanslı, ticari üründe
yeniden dağıtılamaz. Yalnızca CC0 / açıkça ticari izinli olanlar
alınmalı; her kayıtta lisans + kaynak + izin kanıtı zorunlu alan.
(Kullanıcının paylaştığı Neva Leather kalıbı satın alınmış lisanslıydı;
yalnızca **sunum konvansiyonları** incelendi, geometrisi alınmadı.)

---

## 12. Tasarım dili (arayüz)

Konunun kendi dünyasından: **kesim matı** paleti. Koyu yeşil mat, bone
beyazı kesim hatları, pirinç renginde dikiş delikleri, çalk teal kat
çizgileri.

- Mat ızgarası süs değil **ölçüm aracı**: 10mm ince, 50mm kalın
- SVG viewBox doğrudan milimetre, piksel dönüşümü yok
- Her ölçü JetBrains Mono (PDF ile aynı font), etiketler IBM Plex Sans
  Condensed
- Slider tutamakları eşkenar dörtgen (pricking iron ucu)

---

## 13. Hızlı komutlar

```bash
pnpm install
pnpm test                      # 374 test
pnpm typecheck
pnpm --filter @odk/web dev     # http://localhost:5173
pnpm --filter @odk/web build

vercel --prod                  # root directory = repo kökü, apps/web DEĞİL
```

Vercel'de root directory `apps/web` seçilirse kökteki `vercel.json`
okunmaz. Yedek olarak `apps/web/vercel.json` de var ama önerilen yol
kökü seçmek.
