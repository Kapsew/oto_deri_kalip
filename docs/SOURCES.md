# Kaynaklar ve Sayıların Dayanağı

Bu dosya, motordaki her sayısal sabitin nereden geldiğini kaydeder.
Üç kategori var ve karıştırılmamaları kritik:

- **BELGELENMİŞ** — birden fazla bağımsız kaynakta aynı değer
- **TÜRETİLMİŞ** — belgelenmiş değerlerden hesapla çıkarıldı
- **⚠️ GEÇİCİ** — dayanağı yok, akıl yürütmeyle seçildi, Faz 6'da kalibre edilecek

---

## BELGELENMİŞ

### Deri kalınlık birimi
1 oz = 1/64 inç = 0.396875mm. Sektörde "0.4mm" diye yuvarlanıyor; biz tam
değeri kullanıyoruz çünkü 8 oz'da yuvarlama hatası 0.025mm birikiyor.
Kaynak: Weaver Leather Supply, Maverick Leather, Montana Leather, Liberty
Leather Goods — hepsi aynı tanımı veriyor.

### Cüzdan bileşen kalınlıkları
| Bileşen | Aralık | Not |
|---|---|---|
| Dış kabuk | 0.8–1.2mm | bifold'da alt uçta (0.8–1.0) kalmak öneriliyor |
| Kart yuvası | 0.6–0.8mm | kalın olursa yuva esnemez, ürün şişer |
| Bölme | ince | yapısal yük taşımıyor |

MAKESUPPLY: dış kabukta 4 oz üstüne çıkmamak, iç kabuk ve yuvaları
2/3 oz bandında tutmak. Örnek kalıpları 1.2–1.4mm (3/3.5 oz) deriyle.

### Kapalı kalınlık hedefi
İyi yapılmış bifold boşken 6–8mm'yi geçmemeli. Katmanlar kart eklenmeden
bu sınırı aşıyorsa deri seçimi yeniden düşünülmeli.

### Bifold yarım inç kuralı ⭐
MAKESUPPLY: dış kabuk iç kabuktan yaklaşık yarım inç uzun olmalı (iç 8.5″
ise dış 9″). Gerekçe: ikisi aynı ölçüde olursa cüzdan katlanırken
kilitleniyor, kat mesafesini karşılamak için fazladan boşluk gerekiyor.

**Bu kural modelin doğrulama çapası.** 180°'lik katta birbirinden `d`
uzaklıktaki iki katman arasındaki uzunluk farkı `π × d`. Yarım inç =
12.7mm → d = 4.04mm, yani ~4mm'lik kapalı yığın. Bu, belgelenmiş 6–8mm
hedefinin içinde. Zanaatkârın deneyimle bulduğu sayı fiziğin verdiği
sayıyla 0.15mm içinde örtüşüyor.

### T-slot vs stacked kart yuvası ⭐
MAKESUPPLY + Borderland Leather:
- **stacked**: her yuva düz dikdörtgen. Üst üste bindikçe her biri o
  bölgeye bir katman ekliyor → kalın VE dengesiz kenar; en alt yuvaya
  kart sokmak zorlaşıyor.
- **t-slot**: parça "T" şeklinde, yuvanın içindeki deri bölmenin
  kenarına kadar uzanmıyor. Kaç yuva olursa olsun kenarda tek katman
  geçiyor → kenar kalınlığı sabit.
- Pratikte en alt yuva hariç hepsi T-slot; en alttaki dibi kapatmak için
  düz dikdörtgen kalıyor.

Bu ayrım kural motoru için belirleyici: 6 yuvalı cüzdan "stacked" ile
kenarda 4.2mm deri demek, "t-slot" ile 0.7mm.

### Kart bölmesi genişliği
Borderland Leather: bitmiş bölme genişliği yatay kart için ~100mm, dikey
için ~70mm. Kart 85.6 × 53.98mm (ISO/IEC 7810 ID-1, kalınlık 0.76mm).

### T-slot sarma payı
Borderland Leather: T-slot'lar birbirinin üzerine oturduğu ve alttaki
cebin etrafında hafifçe kıvrıldığı için iki yana 2–5mm fazladan pay
bırakıp sonunda fazlalığı kesmek iyi pratik. (Kesit çözücüdeki kıvrım
payının küçük ölçekli versiyonu.)

### Dikiş adımı
3–6mm, iplik kalınlığı ve deri ağırlığına göre. Ticari kalıplarda 3mm ve
4mm sıkça belirtiliyor. Bu, `IRON_PITCHES` listemizi doğruluyor.

### Kademe alt sınırı
Basit üç panelli kartlıkta "üst katman 5mm daha kısa" → kademenin ALT
SINIRI 5mm.

---

## TÜRETİLMİŞ

### Kart kayma boşluğu
Belgelenmiş bölme genişliklerinden geri hesaplandı (iki yanda 3.5mm dikiş
payı varsayımıyla):
- yatay: 100 − 85.60 − 7 = **7.4mm**
- dikey: 70 − 53.98 − 7 = **9.0mm**

Değer yöne göre farklı. Başlangıçta tek sabit (7mm) kullanıldı; dikey
yuvada belgelenmiş 70mm'den 2mm sapıyordu. Kaynaklar iki yön için ayrı
değer verdiğine göre tek sayıya indirgemek veriyi bozmak olurdu.

### Dikiş payı 3.5mm
3mm altı yırtılma riski, 4.5mm üstü malzeme kaybı ve şişkin kenar.
Hobi kalıplarında yaygın değer.

---

## ⚠️ GEÇİCİ — Faz 6'da kalibre edilecek

### k-faktörü (nötr eksen konumu)
**Deri için ölçülmüş veri YOK.** Literatür taramasında bulunan tüm
k-faktörü tabloları sac metal için (tipik aralık 0.33–0.50, iç
yarıçap/kalınlık oranına ve malzemeye göre değişiyor). Deri için
eşdeğer yayınlanmış tablo bulunamadı.

Seçilen değerler bu banttan akıl yürütmeyle:
| Sertlik | k |
|---|---|
| veg-tan-firm | 0.45 |
| veg-tan-soft | 0.40 |
| chrome-soft | 0.38 |

**BÜYÜKLÜK KONTROLÜ (önemli):** 1.2mm deride 180° katta k'yı 0.38'den
0.45'e çekmek düz uzunluğu π × 1.2 × 0.07 ≈ **0.26mm** değiştiriyor. Bu,
el kesim hata payımızın (±0.5mm) altında. Buna karşılık katman öteleme
terimi 4mm yığında 12.6mm — **48 kat daha büyük**.

Sonuç: k'yı yanlış tahmin etmek kalıbı bozmuyor. Asıl belirleyici terim
katman öteleme mesafesi ve o tamamen geometrik, tahmin içermiyor. Bu
iddia `crosssection.test.ts` içinde test olarak sabitlendi — yanlışsa
test kırılır ve k için ölçülmüş veri bulmak zorunlu hale gelir.

### Kademe (reveal) yüksekliği
12mm. Belgelenen tek sayı 5mm alt sınırıydı. Çok yuvalı cüzdanlarda
kademe daha büyük olmak zorunda, yoksa alttaki kartlar görünmez ve
parmakla ayrılamaz. Fiziksel doğrulama gerekiyor.

### Tıraşlama (skiving) azaltma oranı
0.5 (yarıya indirme). Tıraşlamanın kalınlığı ne kadar düşürdüğüne dair
sayısal veri bulunamadı; pratik olarak "belirgin şekilde azaltıyor"
deniyor.

---

## Faz 6'da ölçülecekler

1. Bilinen bir kalıptan üretilmiş kartlıkta her katmanın düz uzunluğu ve
   kapalı kalınlık → k kalibrasyonu
2. Farklı sertliklerde aynı ölçüm → sertlik-k ilişkisi
3. Tıraşlanmış vs tıraşlanmamış örtüşme kalınlığı → skive oranı
4. 4, 6, 8 yuvalı T-slot cüzdanlarda gerçek kademe → reveal doğrulaması

---

## Banknot ölçüleri (Faz 3'te eklendi)

### BELGELENMİŞ
| Para birimi | En büyük kupür | Ölçü |
|---|---|---|
| TRY | 200 TL | **160 × 72 mm** |
| USD | tüm kupürler | **156 × 66.3 mm** |

TCMB: tüm TL banknotları uzun kenarda 6mm, kısa kenarda ikili grup
hâlinde 4mm farkla basılıyor — en büyük kupür diğerlerini kapsıyor.

### ⚠ DOĞRULANMADI
| Para birimi | Kullanılan değer | Not |
|---|---|---|
| EUR | 153 × 77 mm (200 €) | Europa serisi. Eski seri 200/500 € daha büyüktü (160 × 82). |
| GBP | 146 × 77 mm (£50) | Polimer seri. |

Kodda `verified: false` ile işaretli; bu para birimleri seçildiğinde
arayüz ve PDF uyarı gösteriyor.

## Bifold kat payı — dolgu modeli

Yarım inç kuralı (12.7mm) kıvrımda katman olmayan dolgu modellenmeden
üretilemiyor. Yalnızca iki deri katmanıyla model 2.6mm veriyor.

Dolgu = panel başına kart yığını (yuva derileri + kartlar). Model:

| Panel başına yuva | Kat payı | Boş kalınlık |
|---|---|---|
| 1 | 7.2mm | 4.8mm |
| 2 | **11.8mm** | 6.2mm |
| 3 | 16.4mm | 7.6mm |
| 4 | 21.0mm | 9.0mm |

2 yuva satırı MAKESUPPLY'in "bare minimum" tarifine (dış kabuk, iç kabuk,
bir kat kart yuvası) karşılık geliyor ve 12.7mm'ye 0.9mm yakın.

Yarım inç sabit bir sayı değil, belirli bir kalınlığın sonucu. Kalın
cüzdanın daha çok pay istemesi doğru davranış; modeli 12.7'ye zorlamak
hata olurdu.

---

## Çanta askısı (Faz 3'te eklendi)

### BELGELENMİŞ
`drop` = askının tepe noktasından çantanın üst kenarına dikey mesafe.

| Tip | Drop | Toplam uzunluk | Çarpan |
|---|---|---|---|
| Tote sapı | 25–36 cm (10–14″) | ≈ 2 × drop | 2.0 |
| Omuz askısı | 45–60 cm | ≈ 2 × drop | 2.0 |
| Çapraz askı | 51–61 cm | **114–137 cm** | **2.3** |

Çapraz askının çarpanı neden farklı: askı gövdeyi diyagonal kestiği için
omuz askısından daha uzun bir yol izliyor. Kaynaklarda "toplam ≈ 2.3 ×
drop" kuralı ayrıca belirtiliyor ve 2.3 × 55 = 126.5cm, belgelenen
114–137cm bandının ortasına düşüyor.

### Çanta derisi kalınlığı
Panel 1.6–2.4mm (4–6 oz), askı 2.0–3.2mm. Cüzdan derisi (0.6–1.0mm)
burada yetmez; ince panel sarkar, ince askı zamanla uzar ve kopar.

## Körük uzunluğu — hesap, tahmin değil

Körük panelin dikiş hattı boyunca dolanıyor, dolayısıyla uzunluğu o
hattın **yay uzunluğu**:

```
körük = 2·(H − R) + (W − 2R) + 2·(πR/2)
```

Varsayılan (W 220, H 200, R 40): 2×160 + 140 + 125.7 = **585.7mm**

Bu formülde tahmin yok — Adım 4'te kurulan yay uzunluğu makinesinin
doğrudan uygulaması. Köşe yarıçapı büyüdükçe körük KISALIYOR (2R yerine
πR/2 yol gidiliyor); test bunu doğruluyor.

### Üç parçalı bölünme neden yay ortasından
Yay sınırlarından bölmek daha sezgisel ama taban parçasını 285mm'ye
çıkarıp A4'e sığmaz hâle getiriyor. Yay ortasından bölünce her iki parça
da döndürülerek sayfaya sığıyor; ayrıca birleşim düz kenarda değil eğri
üzerinde kalıyor ve daha az göze çarpıyor.
