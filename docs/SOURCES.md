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
