# oto_deri_kalip

El yapımı deri ürünler (cüzdan, kartlık, çanta) için ölçülü, dikiş izli, **A4'e 1:1 basılabilir** kalıp üreten motor ve uygulama.

**Hedef kitle:** A4'e basıp elle kesen hobiciler. Bu karar tüm mimariyi belirliyor — baskı sadakati, lazer hassasiyetinden önce gelir.

---

## Mimari kurallar

Bu üç kural pazarlık konusu değil. Bozulursa geri dönüş maliyeti yüksek.

1. **`packages/geometry` saf kalır.** React, DOM, `fs`, `window` — hiçbiri import edilmez. Tarayıcıda, Node'da ve Capacitor içinde aynı çalışması mobil paketlemenin ön koşulu.
2. **Motorun içinde her uzunluk milimetredir** (`Mm`). Point, inch, piksel yalnızca çıktı katmanında görülür.
3. **Kalıp bir "şekil" değil, bir "kesit çözümüdür."** Dış hatlar elle çizilmez; katman yığınından hesaplanır. Aksi halde her yeni model elle yazılmış yeni bir çizim olur ve sistem 20. modelde çöker.

## Yapı

```
packages/
  geometry/    Saf geometri çekirdeği (birim, vektör, path, yay uzunluğu)
  patterns/    Modül tanımları (CardSlot, BillPocket), kesit çözücü, kural motoru
apps/
  web/         React + Vite kullanıcı arayüzü
  admin/       Kalıp normalizasyon paneli (lisans kaydı zorunlu)
```

## Kurulum

```bash
pnpm install
pnpm test          # tüm paketler
pnpm test:geometry # sadece geometri
pnpm typecheck
```

## Durum

**Faz 0 tamam** — monorepo, TS strict yapılandırma, Vitest.

**Faz 1 kısmen tamam:**

- [x] Birim sistemi — `Mm`, epsilon karşılaştırma, mm↔pt dönüşümü, ISO ID-1 ve iron adım sabitleri
- [x] Vektör primitifleri
- [x] Path modeli — builder, kübik bezier, adaptif düzleştirme, alan/yön/bbox, simplify
- [x] Yay uzunluğu parametrizasyonu — `pointAtDistance` (ikili arama), köşe tespiti, span bölme
- [ ] Clipper2-WASM entegrasyonu (offset, boolean)
- [ ] Kesit çözücü (nötr eksen boyunca kıvrım payı)
- [ ] Dikiş dağıtıcı

72 test geçiyor, typecheck temiz.

## Test felsefesi

Her modül, **elle hesaplanmış referans değerlerle** doğrulanır — 100×50 dikdörtgen (çevre 300, alan 5000, köşeler 0/100/150/250), çeyrek daire yaklaşımı (uzunluk π/2·r), 3-4-5 üçgeni. Kesit çözücüye geçildiğinde gerçek bir kartlığın ölçülmüş değerleri fixture olarak eklenecek.

Kayan nokta tuzakları test edilir, üstü örtülmez: `0.1 + 0.2 !== 0.3` ve `-0 !== +0` ikisi de gerçek hataya yol açtı. Vektör karşılaştırması **her zaman** `vecEq` ile yapılır, `toEqual` ile değil.

## Yol haritası

`docs/ROADMAP.md`
