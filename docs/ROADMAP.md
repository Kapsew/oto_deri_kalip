# Yol Haritası

## Faz 0 — Kurulum ✅

Monorepo (pnpm + Turborepo), TS strict (`noUncheckedIndexedAccess`, `exactOptionalPropertyTypes`), Vitest.

## Faz 1 — Geometri Çekirdeği (devam)

Sıra bağlayıcı; her adım öncekine dayanır.

| # | Adım | Durum |
|---|------|-------|
| 1 | Birim sistemi (`Mm`, EPS=1µm, mm↔pt) | ✅ |
| 2 | Vektör primitifleri | ✅ |
| 3 | Path modeli + bezier düzleştirme | ✅ |
| 4 | Yay uzunluğu parametrizasyonu + köşe tespiti | ✅ |
| 5 | Clipper2-WASM: offset + boolean | ⬜ |
| 6 | **Kesit çözücü** | ⬜ |
| 7 | Dikiş dağıtıcı | ⬜ |

### Adım 6 — Kesit çözücü (motorun kalbi)

Deri kalın olduğu için dış kat iç kattan uzun olmak zorunda. Sabit "+2mm" kuralları 1–2mm sapma üretir.

Yaklaşım: sac metaldeki bend allowance mantığı. Kıvrım payı nötr eksen boyunca yürütülür:

```
90° kıvrımda ek uzunluk ≈ (π/2) · (r + k·t)
k ≈ 0.4–0.5, deri tipine göre kalibre edilir
```

Girdi ürünün genişlik/yüksekliği değil, **katman yığınıdır**: katman sırası, her katmanın kalınlığı, tutkal payı, iç dolgu (kart ≈ 0.76mm).

En çok testi bu adım hak ediyor. Ölçülmüş gerçek bir kartlık fixture olarak eklenecek.

### Adım 7 — Dikiş dağıtıcı

- Yol arc-length'e göre parametrize edilir, **köşeler çapa** kabul edilir (köşede delik yoksa iplik dönüşü bozulur).
- Segment başına `n = round(L / pitch)`, gerçek adım `L / n`.
- Fiziksel iron adımları sabit (2.7 / 3.0 / 3.38 / 3.85 / 4.0 / 5.0mm). Adım değiştirilemez; segment başına ±0.1–0.15mm sapma tolere edilir, fazlalık görünmeyen yere (alt kenar ortası) atılır.
- Elle kesen kullanıcı pricking iron'la kendisi yürüdüğü için çıktı **her deliği tek tek basmaz**: başlangıç deliği merkezi + dikiş çizgisi + "bu kenarda 3.85mm iron ile 14 delik" notu daha kullanışlı ve daha hassas.

## Faz 2 — PDF / Baskı Katmanı

Elle kesende asıl hata kaynağı kalıp matematiği değil, **baskı ölçeği ve çizgi kalınlığı**.

- pdf-lib, 1:1 mm çıktı
- **50mm kalibrasyon karesi** + "Ölçek %100 / Sayfaya sığdır KAPALI" uyarısı
- Kalibrasyon düzeltme döngüsü: kullanıcı kareyi cetvelle ölçüp girer → ölçek otomatik düzeltilir → PDF yeniden üretilir. Ürünü rakiplerinden ayıran özellik bu.
- A4 tiling: %10 bindirme, hizalama haçları, sayfa kodları (A1/A2/B1)
- Çizgi tipleri **desen ile ayrışır, renk ile değil** (herkeste renkli yazıcı yok): kesim 0.2mm hairline, dikiş kesikli, kat noktalı, tutkal taralı
- Kural: "çizginin dışından kes" — 0.5mm çizgide belirsizlik iki kenarda 1mm kaybettirir
- Parça etiketleri: ad, adet, ×2 ayna işareti, grain yönü, üst/iç yüz, versiyon + ölçek damgası
- Kalem payı ayarı: 0 / 0.3 / 0.5mm (kartona yapıştırıp deriye çizerken kalem ucu dışa kaçar)

**Kapı:** Buradan çıkan ilk PDF yazdırılıp cetvelle ölçülür. Sapma varsa Faz 3'e geçilmez.

## Faz 3 — Modül Sistemi

Modüller: `CardSlot(n)`, `BillPocket(depth, currency)`, `CoinPocket(zip|flap|origami)`, `IDWindow`, `HiddenPocket`, `Gusset(depth)`, `Divider`.

MVP'de yalnızca **`CardSlot` + `BillPocket`**, n ∈ 3..8.

Her modül bildirir: kalınlık katkısı, gerekli yükseklik, kendi parçaları.

İskeletler: kartlık, bifold, uzun cüzdan. Kullanıcı serbest yerleşim kurmaz — iskelet seçip içini doldurur. Bu kural motorunu ciddi ölçüde basitleştirir.

**Kural motoru** (bunsuz saçma modeller üretir):

- Kapalı kalınlık > 18–20mm → uyarı, cep cüzdanı olmaktan çıkıyor
- Banknot derinliği < banknot yüksekliği − 8mm (para dışarı görünmesin)
- Üst kart yuvası ağzı kapak kenarından ≥ 8mm içeride
- Fermuar modülü → gusset zorunlu
- Toplam yükseklik > A4 → tiling zorunlu, baştan bildir

Referans hesap: 5 kartlı kademeli yuva ≈ 54 + 4×14 = 110mm + kat payları. Yuva genişliği = 54 + 3–4mm boşluk.

## Faz 4 — Admin Normalizasyon Paneli

⚠️ **Lisans uyarısı:** İnternetteki bedava kalıpların çoğu "kişisel kullanım" lisanslı, ticari üründe yeniden dağıtılamaz. Kalıp çizimi çoğu yargı alanında telif konusu.

- Yalnızca CC0 / açıkça ticari izinli kalıplar alınır
- Her kayıtta **lisans + kaynak URL + izin kanıtı zorunlu alan** — boş geçilemez
- İndirilen PDF/JPG ölü pikseldir; motor kesit + modül şemasıyla çalışır. Dönüşüm otomatik değil, **elle normalizasyon** gerekir.
- Hedef: 30–50 kalıp. 500 ham kalıptan 50 doğru normalize kalıp çok daha değerli — aynı şemada olduğu için istatistik ve varyasyon anlamlı hale gelir.

## Faz 5 — Web Uygulaması

React + Vite, SVG render. Akış: iskelet seç → modül/slider → önizleme → kalibrasyon → PDF indir.

PostHog eventleri: kalıp seçimi, parametre değişimi, indirme.

Motor tarayıcıda çalıştığı için PDF üretimi tamamen client-side — sunucu maliyeti ~sıfır, çevrimdışı çalışır.

## Faz 6 — Fiziksel Doğrulama

**Atlanmaz.** 5–6 kişiye 3 farklı kalıp bastırılır, kesilip dikilir, sapmalar ölçülür. Yazıcı kaynaklı hatalar kalıp hatalarından ayrılır, k-katsayıları kalibre edilir. 10–15 fiziksel iterasyon sonrası ±0.5mm altına inilir.

Bu adım atlanırsa uygulama "doğru görünen ama işe yaramayan" kalıplar üretir — bu pazardaki en yaygın başarısızlık.

## Faz 7 — İstatistik + Varyasyon

**Bu ML değil, veri de yetmez.** Yöntem: parametre zarfı örnekleme.

1. Kullanım verisinden her parametrenin dağılımı çıkarılır (kart sayısı çoğunlukla 4–6, kademe 12–14mm, dış yükseklik 95–105mm)
2. Yeni varyasyon = zarftan örnekle → kural motorundan geçir → geçenleri sun
3. Benzerlik skoru: mevcut kalıba %90'dan fazla benzeyen önerilmez

Şeffaf, hata ayıklanabilir, 200 kullanıcıyla bile çalışır. LLM/ML ancak binlerce kullanım sonrası düşünülür. En az 100–200 gerçek kullanım verisi birikmeden açılmaz.

## Faz 8 — Mobil

Capacitor ile aynı web kodu paketlenir. **React Native'e gidilmez** — SVG/PDF katmanı ikinci kez yazılır, bu ürün için gereksiz maliyet.

## Teknoloji

| Katman | Seçim |
|--------|-------|
| Monorepo | pnpm + Turborepo |
| Geometri | saf TS + Clipper2-WASM |
| Çıktı | pdf-lib (mm bazlı), SVG |
| Web | React + Vite, SVG render |
| Mobil | Capacitor |
| Backend | Supabase (Postgres + auth + storage) |
| Analitik | PostHog |
