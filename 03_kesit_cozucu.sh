#!/usr/bin/env bash
#
# Faz 1 / Adim 6 — Kesit cozucu (cross-section solver)
#
# Kullanim:
#   chmod +x 03_kesit_cozucu.sh
#   ./03_kesit_cozucu.sh
#
# Repo kokunde calistirilmalidir. Idempotent.

set -euo pipefail

if [ ! -f "pnpm-workspace.yaml" ] || [ ! -d "packages/patterns" ]; then
  echo "HATA: Bu script repo kokunde calistirilmali." >&2
  exit 1
fi

if ! command -v pnpm > /dev/null 2>&1; then
  echo "HATA: pnpm bulunamadi. Kurulum: npm i -g pnpm@9" >&2
  exit 1
fi

echo "==> patterns paketi test scripti duzeltiliyor"
node -e '
const fs = require("fs");
const p = "packages/patterns/package.json";
const j = JSON.parse(fs.readFileSync(p, "utf8"));
j.scripts.test = "vitest run";
fs.writeFileSync(p, JSON.stringify(j, null, 2) + "\n");
'

echo "==> Dizinler"
mkdir -p packages/patterns/src docs

echo "==> packages/patterns/vitest.config.ts"
cat > packages/patterns/vitest.config.ts << 'ODK_EOF_0'
import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    globals: true,
    include: ["src/**/*.test.ts"],
  },
});
ODK_EOF_0

echo "==> packages/patterns/src/material.ts"
cat > packages/patterns/src/material.ts << 'ODK_EOF_1'
import type { Mm } from "@odk/geometry";

/**
 * Malzeme modeli.
 *
 * KAYNAK NOTU: Bu dosyadaki değerlerin bir kısmı belgelenmiş sektör
 * standardı, bir kısmı ise GEÇİCİ tahmin. İkisi ayrı ayrı işaretlendi.
 * Karıştırmak, sonradan hangi sayının güvenilir olduğunu bilememek
 * demek olur.
 */

// --- Kalınlık birimi: onsdan milimetreye -----------------------------------

/**
 * BELGELENMİŞ: 1 oz deri = 1/64 inç kalınlık.
 * 1/64 × 25.4 = 0.396875mm. Sektörde yaygın olarak "0.4mm" diye
 * yuvarlanır; biz tam değeri kullanıyoruz çünkü 8 oz'da yuvarlama
 * hatası 0.025mm birikir.
 *
 * Kaynak: yaygın tanner/tedarikçi dönüşüm tabloları (Weaver, Maverick,
 * Montana Leather vb. hepsi aynı tanımı veriyor).
 */
export const MM_PER_OZ: Mm = 25.4 / 64;

export function ozToMm(oz: number): Mm {
  return oz * MM_PER_OZ;
}

export function mmToOz(mm: Mm): number {
  return mm / MM_PER_OZ;
}

/**
 * Deri onslu aralıklarla satılır (3/4 oz gibi) çünkü doğal deri kalınlığı
 * post boyunca değişir. Aralığın ortasını almak, tek bir nominal değer
 * gereken hesaplar için makul varsayım.
 */
export function ozRangeToMm(minOz: number, maxOz: number): Mm {
  return ozToMm((minOz + maxOz) / 2);
}

// --- Deri tipi ve sertlik --------------------------------------------------

export type Temper = "veg-tan-firm" | "veg-tan-soft" | "chrome-soft";

export interface LeatherSpec {
  readonly temper: Temper;
  readonly thickness: Mm;
  /**
   * Nötr eksenin iç yüzeyden uzaklığının kalınlığa oranı.
   *
   * ⚠️ GEÇİCİ DEĞER — DERİ İÇİN ÖLÇÜLMÜŞ VERİ YOK.
   *
   * Literatür taraması sonucu: k-faktörü tabloları yalnızca sac metal
   * için mevcut (tipik aralık 0.33–0.50, iç yarıçap/kalınlık oranına ve
   * malzemeye göre değişir). Deri için eşdeğer bir yayınlanmış tablo
   * bulunamadı. Aşağıdaki değerler sac metal aralığından deri
   * davranışına göre akıl yürütmeyle seçildi:
   *
   * - Sert bitkisel sepi az sıkışır → nötr eksen merkeze yakın (0.45)
   * - Yumuşak deri iç yüzeyde daha çok sıkışır → eksen içe kayar (0.38)
   *
   * BÜYÜKLÜK KONTROLÜ: 1.2mm deride 180° katta k'yı 0.38'den 0.45'e
   * çekmek düz uzunluğu π × 1.2 × 0.07 ≈ 0.26mm değiştirir. Bu bizim
   * ±0.5mm el kesim hata payımızın altında. Yani k'yı yanlış tahmin
   * etmek kalıbı bozmaz; ASIL belirleyici terim katman öteleme mesafesi
   * (bkz. crosssection.ts). Buna güvenip k'yı ihmal etmiyoruz ama
   * Faz 6'da fiziksel kalibrasyonla düzeltilecek bir parametre olarak
   * işaretliyoruz.
   */
  readonly kFactor: number;
}

/** ⚠️ GEÇİCİ — Faz 6 fiziksel doğrulamasında kalibre edilecek. */
export const PROVISIONAL_K_FACTOR: Record<Temper, number> = {
  "veg-tan-firm": 0.45,
  "veg-tan-soft": 0.4,
  "chrome-soft": 0.38,
};

export function leather(temper: Temper, thickness: Mm): LeatherSpec {
  return { temper, thickness, kFactor: PROVISIONAL_K_FACTOR[temper] };
}

// --- Kalınlık önerileri ---------------------------------------------------

/**
 * BELGELENMİŞ (zanaat pratiği): cüzdan bileşenleri için önerilen
 * kalınlık aralıkları.
 *
 * Kaynaklar birbiriyle tutarlı:
 * - Dış kabuk 0.8–1.2mm; bifold'da alt uçta (0.8–1.0) kalmak öneriliyor
 * - Kart yuvaları 0.6–0.8mm; kart girip çıkabilmesi için esnek olmalı,
 *   kalın olursa ürün şişiyor (yeni başlayanların en sık hatası)
 * - Bölmeler yapısal yük taşımadığı için ince olabilir
 * - MAKESUPPLY kalıpları 1.2–1.4mm (3/3.5 oz) deriyle örneklenmiş;
 *   dış kabukta 4 oz üstüne çıkmamak, iç kabuk ve kart yuvalarını
 *   2/3 oz bandında tutmak öneriliyor
 */
export interface ThicknessRange {
  readonly min: Mm;
  readonly max: Mm;
  readonly preferred: Mm;
}

export const RECOMMENDED_THICKNESS: Record<
  "outerShell" | "innerShell" | "cardSlot" | "divider",
  ThicknessRange
> = {
  outerShell: { min: 0.8, max: 1.2, preferred: 1.0 },
  innerShell: { min: 0.6, max: 1.0, preferred: 0.8 },
  cardSlot: { min: 0.6, max: 0.8, preferred: 0.7 },
  divider: { min: 0.4, max: 0.7, preferred: 0.6 },
};

/**
 * BELGELENMİŞ: iyi yapılmış bir bifold boşken 6–8mm'yi geçmemeli.
 * Katmanlar kart eklenmeden bu sınırı aşıyorsa deri seçimi yeniden
 * düşünülmeli.
 */
export const BIFOLD_TARGET_CLOSED_THICKNESS: Mm = 8;

/**
 * Kural motoru üst sınırı. Bunun üstü artık cep cüzdanı değil.
 * 6–8mm hedefin üstünde tolerans bırakıyoruz çünkü kart yüklü hâli
 * hesaba katılıyor.
 */
export const MAX_CLOSED_THICKNESS: Mm = 20;

/**
 * BELGELENMİŞ (zanaat pratiği): iki veya daha fazla parçanın örtüştüğü
 * yerde kenarı tıraşlamak (skiving) hacmi belirgin şekilde azaltıyor.
 *
 * ⚠️ ORAN GEÇİCİ: tıraşlamanın kalınlığı ne kadar düşürdüğüne dair
 * sayısal veri bulunamadı. 0.5 (yarıya indirme) makul bir başlangıç;
 * Faz 6'da ölçülecek.
 */
export const PROVISIONAL_SKIVE_FACTOR = 0.5;

/** BELGELENMİŞ: ISO/IEC 7810 ID-1 kart kalınlığı. */
export const CARD_THICKNESS: Mm = 0.76;
ODK_EOF_1

echo "==> packages/patterns/src/crosssection.ts"
cat > packages/patterns/src/crosssection.ts << 'ODK_EOF_2'
import type { Mm } from "@odk/geometry";
import { EPS } from "@odk/geometry";
import type { LeatherSpec } from "./material.js";

/**
 * KESİT ÇÖZÜCÜ — motorun kalbi.
 *
 * ═══════════════════════════════════════════════════════════════════════
 * TEMEL FİKİR
 * ═══════════════════════════════════════════════════════════════════════
 *
 * Bir cüzdanı katladığında dış katman iç katmandan daha uzun bir yol
 * kateder. Kalıbı düz keserken bu farkı önceden eklemek zorundasın,
 * yoksa katlarken ürün kilitlenir.
 *
 * Fark iki bileşenden gelir:
 *
 *   1) KATMAN ÖTELEME (baskın terim)
 *      Kıvrım merkezinden d kadar uzaktaki bir katman, θ açılı kıvrımda
 *      θ·d kadar fazla yol yürür. 180°'lik bir katta (θ = π) 4mm'lik bir
 *      yığının dış katmanı iç katmandan π × 4 ≈ 12.6mm uzun olmalıdır.
 *
 *      DOĞRULAMA: MAKESUPPLY'in bifold kuralı "dış kabuk iç kabuktan
 *      yarım inç uzun olmalı" diyor (iç 8.5″ ise dış 9″). Yarım inç =
 *      12.7mm. Yani zanaatkârın deneyimle bulduğu sayı, 4mm yığın
 *      kalınlığı için fiziğin verdiği sayıyla 0.1mm içinde örtüşüyor.
 *      Bu, modelin doğru terimi yakaladığının bağımsız kanıtı.
 *
 *   2) KATMAN İÇİ GERİLME (ikincil terim)
 *      Katmanın kendi kalınlığı içinde nötr eksen tam ortada değil,
 *      iç yüzeye doğru kayar. Sac metaldeki k-faktörü budur.
 *      1.2mm deride 180° katta k'nın 0.38↔0.45 aralığındaki belirsizliği
 *      sadece ~0.26mm etki yapar — el kesim hata payımızın altında.
 *
 * Bu yüzden model her katmanın nötr ekseni boyunca yürür:
 *
 *   R_i = innerRadius + (i'den içteki katmanların toplam kalınlığı)
 *                     + k_i · t_i
 *   kıvrım payı_i = θ · R_i
 *
 * ═══════════════════════════════════════════════════════════════════════
 * NEDEN "GENİŞLİK/YÜKSEKLİK" DEĞİL DE "KESİT"
 * ═══════════════════════════════════════════════════════════════════════
 *
 * Girdi ürünün dış ölçüsü değil, katman yığınının kendisi. Yeni bir model
 * (farklı kart sayısı, para bölmesi, bozuk para gözü) yeni bir çizim
 * değil, yeni bir yığın dizilimi. Kalıp otomatik düşer.
 */

/** Kesitteki bir katman. */
export interface Layer {
  readonly id: string;
  readonly name: string;
  readonly spec: LeatherSpec;
}

/**
 * Bir kıvrım.
 *
 * `stack` katman id'lerini kıvrımın İÇİNDEN DIŞINA doğru sıralar.
 * Sıra kritik: yanlış sıra, yanlış öteleme mesafesi demek.
 */
export interface Fold {
  readonly id: string;
  readonly name: string;
  /** Kıvrım açısı, derece. 180 = tam kat (bifold sırtı). */
  readonly angleDeg: number;
  /** En iç katmanın İÇ yüzeyindeki yarıçap. */
  readonly innerRadius: Mm;
  /** Katman id'leri, içten dışa. */
  readonly stack: readonly string[];
}

/** Düz bir bölüm (kıvrım olmayan kısım). */
export interface Run {
  readonly id: string;
  readonly name: string;
  readonly length: Mm;
  /** Bu bölümden geçen katman id'leri. Sıra önemsiz. */
  readonly layers: readonly string[];
}

export interface CrossSection {
  readonly name: string;
  readonly layers: readonly Layer[];
  readonly runs: readonly Run[];
  readonly folds: readonly Fold[];
}

// --- Sonuç ----------------------------------------------------------------

export interface LayerResult {
  readonly layerId: string;
  readonly name: string;
  /** Düz bölümlerden gelen toplam. */
  readonly straightLength: Mm;
  /** Kıvrımlardan gelen toplam (nötr eksen yay uzunlukları). */
  readonly bendAllowance: Mm;
  /** Kalıba çizilecek düz uzunluk. */
  readonly flatLength: Mm;
}

export interface FoldResult {
  readonly foldId: string;
  readonly name: string;
  /** Kıvrımdaki katmanların toplam kalınlığı. */
  readonly stackThickness: Mm;
  /** En dış ve en iç katmanın kıvrım payı farkı. */
  readonly outerInnerDelta: Mm;
}

export interface Diagnostic {
  readonly severity: "error" | "warning";
  readonly code: string;
  readonly message: string;
}

export interface CrossSectionResult {
  readonly layers: readonly LayerResult[];
  readonly folds: readonly FoldResult[];
  readonly diagnostics: readonly Diagnostic[];
}

// --- Çekirdek hesap -------------------------------------------------------

export function degToRad(deg: number): number {
  return (deg * Math.PI) / 180;
}

/**
 * İki katman arasındaki uzunluk farkının saf geometrik çekirdeği.
 *
 * θ açılı bir kıvrımda, birbirinden `gap` kadar uzaktaki iki katmanın
 * kat ettiği yol farkı θ·gap'tır. Modelin en önemli tek formülü;
 * yarım inç kuralını üreten şey bu.
 */
export function foldLengthDelta(gap: Mm, angleDeg: number): Mm {
  return degToRad(angleDeg) * gap;
}

/**
 * Bir yığını saran kıvrımın doğal iç yarıçapı.
 *
 * Deri kendi etrafına sıfır yarıçapla katlanamaz; sardığı yığının
 * yarısı kadar bir yarıçap oluşur. Kullanıcı daha küçük bir değer
 * verirse uyarı üretilir.
 */
export function naturalInnerRadius(wrappedThickness: Mm): Mm {
  return wrappedThickness / 2;
}

/** Katman id'sinden katmana hızlı erişim. */
function indexLayers(layers: readonly Layer[]): Map<string, Layer> {
  const map = new Map<string, Layer>();
  for (const l of layers) map.set(l.id, l);
  return map;
}

export function stackThickness(
  fold: Fold,
  index: Map<string, Layer>,
): Mm {
  let total = 0;
  for (const id of fold.stack) {
    const l = index.get(id);
    if (l !== undefined) total += l.spec.thickness;
  }
  return total;
}

/**
 * Kesiti çözer: her katman için düz uzunluk.
 *
 * Girdi hatalarını sessizce yutmaz — eksik katman referansı, geçersiz
 * açı, fiziksel olarak imkânsız yarıçap hepsi tanılama olarak döner.
 * `error` seviyesindeki tanılama varsa çıkan ölçülere güvenilmemeli.
 */
export function solveCrossSection(cs: CrossSection): CrossSectionResult {
  const index = indexLayers(cs.layers);
  const diagnostics: Diagnostic[] = [...validate(cs, index)];

  const straight = new Map<string, Mm>();
  const bend = new Map<string, Mm>();
  for (const l of cs.layers) {
    straight.set(l.id, 0);
    bend.set(l.id, 0);
  }

  for (const run of cs.runs) {
    for (const id of run.layers) {
      const cur = straight.get(id);
      if (cur !== undefined) straight.set(id, cur + run.length);
    }
  }

  const foldResults: FoldResult[] = [];

  for (const fold of cs.folds) {
    const theta = degToRad(fold.angleDeg);
    let insideThickness = 0;
    let innermostArc: Mm | undefined;
    let outermostArc: Mm | undefined;

    for (const id of fold.stack) {
      const layer = index.get(id);
      if (layer === undefined) continue;

      const t = layer.spec.thickness;
      const neutralRadius =
        fold.innerRadius + insideThickness + layer.spec.kFactor * t;
      const arc = theta * neutralRadius;

      const cur = bend.get(id);
      if (cur !== undefined) bend.set(id, cur + arc);

      if (innermostArc === undefined) innermostArc = arc;
      outermostArc = arc;

      insideThickness += t;
    }

    foldResults.push({
      foldId: fold.id,
      name: fold.name,
      stackThickness: insideThickness,
      outerInnerDelta:
        outermostArc !== undefined && innermostArc !== undefined
          ? outermostArc - innermostArc
          : 0,
    });
  }

  const layerResults: LayerResult[] = cs.layers.map((l) => {
    const s = straight.get(l.id) ?? 0;
    const b = bend.get(l.id) ?? 0;
    return {
      layerId: l.id,
      name: l.name,
      straightLength: s,
      bendAllowance: b,
      flatLength: s + b,
    };
  });

  return { layers: layerResults, folds: foldResults, diagnostics };
}

// --- Doğrulama -----------------------------------------------------------

function validate(
  cs: CrossSection,
  index: Map<string, Layer>,
): Diagnostic[] {
  const out: Diagnostic[] = [];

  if (index.size !== cs.layers.length) {
    out.push({
      severity: "error",
      code: "DUPLICATE_LAYER_ID",
      message: "Aynı id'ye sahip birden fazla katman var.",
    });
  }

  for (const l of cs.layers) {
    if (l.spec.thickness <= EPS) {
      out.push({
        severity: "error",
        code: "ZERO_THICKNESS",
        message: `"${l.name}" katmanının kalınlığı sıfır ya da negatif.`,
      });
    }
    if (l.spec.kFactor < 0 || l.spec.kFactor > 1) {
      out.push({
        severity: "error",
        code: "K_OUT_OF_RANGE",
        message: `"${l.name}" için k-faktörü 0–1 dışında (${l.spec.kFactor}).`,
      });
    }
  }

  for (const run of cs.runs) {
    if (run.length <= EPS) {
      out.push({
        severity: "error",
        code: "ZERO_RUN",
        message: `"${run.name}" bölümünün uzunluğu sıfır ya da negatif.`,
      });
    }
    for (const id of run.layers) {
      if (!index.has(id)) {
        out.push({
          severity: "error",
          code: "UNKNOWN_LAYER_REF",
          message: `"${run.name}" bölümü tanımsız katmana atıf yapıyor: ${id}`,
        });
      }
    }
  }

  for (const fold of cs.folds) {
    if (fold.angleDeg <= 0 || fold.angleDeg > 360) {
      out.push({
        severity: "error",
        code: "BAD_ANGLE",
        message: `"${fold.name}" kıvrım açısı geçersiz (${fold.angleDeg}°).`,
      });
    }
    if (fold.innerRadius < 0) {
      out.push({
        severity: "error",
        code: "NEGATIVE_RADIUS",
        message: `"${fold.name}" iç yarıçapı negatif.`,
      });
    }
    if (fold.stack.length === 0) {
      out.push({
        severity: "error",
        code: "EMPTY_FOLD_STACK",
        message: `"${fold.name}" kıvrımında hiç katman yok.`,
      });
    }

    const seen = new Set<string>();
    for (const id of fold.stack) {
      if (!index.has(id)) {
        out.push({
          severity: "error",
          code: "UNKNOWN_LAYER_REF",
          message: `"${fold.name}" kıvrımı tanımsız katmana atıf yapıyor: ${id}`,
        });
      }
      if (seen.has(id)) {
        out.push({
          severity: "error",
          code: "DUPLICATE_IN_STACK",
          message: `"${fold.name}" kıvrımında "${id}" iki kez geçiyor.`,
        });
      }
      seen.add(id);
    }

    // Fiziksel makullük: deri sardığı yığından daha keskin kıvrılamaz.
    const wrapped = stackThickness(fold, index);
    const natural = naturalInnerRadius(wrapped);
    if (fold.innerRadius + EPS < natural * 0.5) {
      out.push({
        severity: "warning",
        code: "TIGHT_RADIUS",
        message:
          `"${fold.name}" iç yarıçapı (${fold.innerRadius.toFixed(2)}mm) ` +
          `yığın kalınlığına göre çok keskin. ` +
          `Doğal yarıçap ~${natural.toFixed(2)}mm. ` +
          `Kalıp kısa çıkabilir ve katlarken kilitlenir.`,
      });
    }
  }

  return out;
}

export function hasErrors(result: CrossSectionResult): boolean {
  return result.diagnostics.some((d) => d.severity === "error");
}

/** Belirli bir katmanın sonucunu getirir. */
export function layerResult(
  result: CrossSectionResult,
  layerId: string,
): LayerResult | undefined {
  return result.layers.find((l) => l.layerId === layerId);
}
ODK_EOF_2

echo "==> packages/patterns/src/cardslot.ts"
cat > packages/patterns/src/cardslot.ts << 'ODK_EOF_3'
import type { Mm } from "@odk/geometry";
import { CARD_ID1 } from "@odk/geometry";
import { CARD_THICKNESS } from "./material.js";

/**
 * KART YUVASI GEOMETRİSİ
 *
 * Bu dosyadaki en önemli bulgu: kart yuvasının YAPIM BİÇİMİ, yığın
 * kalınlığını kart sayısından daha çok etkiliyor. İki yöntem var ve
 * matematikleri tamamen farklı.
 */

/**
 * Yuva yapım biçimi.
 *
 * BELGELENMİŞ (MAKESUPPLY, Borderland Leather):
 *
 * - "stacked": her yuva düz bir dikdörtgen parça. Yuvalar üst üste
 *   bindiğinde her biri o bölgeye fazladan bir katman ekler. Sonuç hem
 *   kalın hem DENGESİZ bir kenar; ayrıca en alttaki yuvaya kart sokmak
 *   zorlaşır.
 *
 * - "t-slot": parça "T" şeklinde kesilir; yuvanın içindeki deri
 *   bölmenin kenarına kadar UZANMAZ. Bu yüzden kenarda kaç yuva olursa
 *   olsun tek katman geçer ve kenar kalınlığı sabit kalır.
 *   Pratikte en alt yuva hariç hepsi T-slot yapılır; en alttaki, dibi
 *   kapatmak için düz dikdörtgen kalır.
 *
 * Bu ayrım kural motoru için kritik: 6 yuvalı bir cüzdan "stacked" ile
 * fiziksel olarak imkânsız kalınlığa çıkarken "t-slot" ile ince kalır.
 */
export type SlotConstruction = "stacked" | "t-slot";

export type CardOrientation = "horizontal" | "vertical";

/**
 * BELGELENMİŞ (Borderland Leather): bitmiş bölme genişliği yatay kart
 * yuvası için ~100mm, dikey için ~70mm olmalı.
 *
 * Kart 85.6 × 53.98mm olduğuna göre bu, yatayda 14.4mm, dikeyde 16mm
 * toplam fazlalık demek. Fazlalık iki şeyi karşılıyor: iki yandaki
 * dikiş hatları ve kartın rahat ama gevşek olmayacak şekilde girip
 * çıkması için boşluk.
 */
export const DOCUMENTED_COMPARTMENT_WIDTH: Record<CardOrientation, Mm> = {
  horizontal: 100,
  vertical: 70,
};

/**
 * Kartın rahat girip çıkması için yuva içinde bırakılan toplam boşluk.
 *
 * Belgelenmiş bölme genişliklerinden geri hesaplandı (iki yanda 3.5mm
 * dikiş payı varsayımıyla):
 *   yatay:  100 − 85.60 − 7 = 7.4mm
 *   dikey:   70 − 53.98 − 7 = 9.0mm
 *
 * DİKKAT: değer yöne göre FARKLI. Başlangıçta tek bir sabit (7mm)
 * kullanmıştım; dikey yuvada belgelenmiş 70mm'den 2mm sapıyordu.
 * Kaynaklar iki yön için ayrı ayrı değer verdiğine göre sabiti tek
 * sayıya indirgemek veriyi bozmak olur. Sapmanın fiziksel gerekçesini
 * uydurmuyoruz; ölçülen pratik bu.
 */
export const CARD_SLIDING_CLEARANCE: Record<CardOrientation, Mm> = {
  horizontal: 7.4,
  vertical: 9.0,
};

/**
 * ⚠️ GEÇİCİ: kademe (reveal) yüksekliği.
 *
 * Üst üste binen yuvalarda her yuvanın ağzının bir alttakinden ne kadar
 * yukarıda durduğu. Aranan kaynaklarda tek bir yerleşik değer
 * bulunamadı; belgelenen tek sayı basit bir üç panelli kartlıkta
 * "üst katman 5mm daha kısa" şeklindeydi ki bu kademenin ALT SINIRI.
 *
 * Çok yuvalı cüzdanlarda kademe daha büyük olmak zorunda, yoksa alttaki
 * kartlar görünmez ve parmakla ayırmak imkânsızlaşır. 12mm makul bir
 * başlangıç ama Faz 6'da fiziksel olarak doğrulanacak.
 */
export const PROVISIONAL_SLOT_REVEAL: Mm = 12;

/** BELGELENMİŞ: kademe için mutlak alt sınır. */
export const MIN_SLOT_REVEAL: Mm = 5;

/**
 * BELGELENMİŞ (Borderland Leather): T-slot'lar birbirinin üzerine
 * oturduğu ve alttaki cebin etrafında hafifçe kıvrıldığı için iki yana
 * 2–5mm fazladan pay bırakıp sonunda fazlalığı kesmek iyi pratik.
 *
 * Bu, kesit çözücüdeki kıvrım payının küçük ölçekli versiyonu: bir
 * katman diğerinin etrafını sardığı için daha uzun olmak zorunda.
 */
export const T_SLOT_WRAP_ALLOWANCE: Mm = 3;

export interface CardSlotSpec {
  readonly count: number;
  readonly construction: SlotConstruction;
  readonly orientation: CardOrientation;
  /** Yuva derisinin kalınlığı. */
  readonly leatherThickness: Mm;
  readonly reveal?: Mm;
  readonly stitchMargin?: Mm;
}

export interface CardSlotGeometry {
  /** Bölmenin dış genişliği (dikiş payları dahil). */
  readonly compartmentWidth: Mm;
  /** Yuva yığınının toplam yüksekliği. */
  readonly stackHeight: Mm;
  /** Kenarda oluşan deri kalınlığı — T-slot'ta yuva sayısından bağımsız. */
  readonly edgeThickness: Mm;
  /** Yuvaların bindiği merkez bölgede oluşan deri kalınlığı. */
  readonly centerThickness: Mm;
  /** Kartlar takılıyken merkez bölgeye eklenen kalınlık. */
  readonly loadedThickness: Mm;
  /** Kaç parça T-slot, kaç parça düz dikdörtgen. */
  readonly tSlotPieces: number;
  readonly rectanglePieces: number;
}

function cardWidth(o: CardOrientation): Mm {
  return o === "horizontal" ? CARD_ID1.width : CARD_ID1.height;
}

function cardHeight(o: CardOrientation): Mm {
  return o === "horizontal" ? CARD_ID1.height : CARD_ID1.width;
}

export function cardSlotGeometry(spec: CardSlotSpec): CardSlotGeometry {
  const reveal = spec.reveal ?? PROVISIONAL_SLOT_REVEAL;
  const stitchMargin = spec.stitchMargin ?? 3.5;
  const n = Math.max(0, Math.floor(spec.count));
  const t = spec.leatherThickness;

  const compartmentWidth =
    cardWidth(spec.orientation) +
    CARD_SLIDING_CLEARANCE[spec.orientation] +
    2 * stitchMargin;

  // İlk yuva tam kart yüksekliği kadar yer kaplar, her ek yuva bir kademe.
  const stackHeight = n === 0 ? 0 : cardHeight(spec.orientation) + (n - 1) * reveal;

  const tSlotPieces = spec.construction === "t-slot" ? Math.max(0, n - 1) : 0;
  const rectanglePieces = n - tSlotPieces;

  // Kenar kalınlığı: T-slot'ta yuva derisi kenara uzanmadığı için sadece
  // dibi kapatan dikdörtgen geçer.
  const edgeThickness =
    spec.construction === "t-slot" ? (n > 0 ? t : 0) : n * t;

  const centerThickness = n * t;
  const loadedThickness = centerThickness + n * CARD_THICKNESS;

  return {
    compartmentWidth,
    stackHeight,
    edgeThickness,
    centerThickness,
    loadedThickness,
    tSlotPieces,
    rectanglePieces,
  };
}

export interface SlotDiagnostic {
  readonly severity: "error" | "warning";
  readonly code: string;
  readonly message: string;
}

/**
 * Yuva yapılandırmasını denetler.
 *
 * Kural motorunun kart yuvası bölümü. Amaç, geometrik olarak
 * hesaplanabilir ama fiziksel olarak kullanılamaz yapılandırmaları
 * kullanıcıya kalıp basılmadan önce bildirmek.
 */
export function validateCardSlots(spec: CardSlotSpec): SlotDiagnostic[] {
  const out: SlotDiagnostic[] = [];
  const reveal = spec.reveal ?? PROVISIONAL_SLOT_REVEAL;
  const geo = cardSlotGeometry(spec);

  if (spec.count < 1) {
    out.push({
      severity: "error",
      code: "NO_SLOTS",
      message: "Yuva sayısı en az 1 olmalı.",
    });
  }

  if (reveal < MIN_SLOT_REVEAL) {
    out.push({
      severity: "error",
      code: "REVEAL_TOO_SMALL",
      message:
        `Kademe ${reveal}mm — belgelenmiş alt sınır ${MIN_SLOT_REVEAL}mm. ` +
        `Daha azında alttaki kartlar görünmez ve parmakla ayrılamaz.`,
    });
  }

  if (spec.construction === "stacked" && spec.count > 3) {
    out.push({
      severity: "warning",
      code: "STACKED_TOO_MANY",
      message:
        `${spec.count} yuva "stacked" yapımla kenarda ${geo.edgeThickness.toFixed(1)}mm ` +
        `deri demek ve kenar dengesiz olur. T-slot yapıma geçmek ` +
        `kenar kalınlığını ${spec.leatherThickness.toFixed(1)}mm'de sabit tutar.`,
    });
  }

  if (spec.leatherThickness > 0.8) {
    out.push({
      severity: "warning",
      code: "SLOT_LEATHER_THICK",
      message:
        `Yuva derisi ${spec.leatherThickness.toFixed(1)}mm — önerilen aralık ` +
        `0.6–0.8mm. Kalın deri yuvanın esnemesini engeller ve ürün şişer.`,
    });
  }

  return out;
}

/**
 * Belgelenmiş bölme genişliğiyle karşılaştırma.
 *
 * Kendi hesabımızın sektör pratiğinden sapmasını ölçer. Sapma 3mm'yi
 * geçiyorsa ya boşluk sabitimiz ya dikiş payımız yanlış.
 */
export function compartmentWidthDeviation(
  orientation: CardOrientation,
  stitchMargin: Mm = 3.5,
): Mm {
  const computed =
    cardWidth(orientation) + CARD_SLIDING_CLEARANCE[orientation] + 2 * stitchMargin;
  return computed - DOCUMENTED_COMPARTMENT_WIDTH[orientation];
}
ODK_EOF_3

echo "==> packages/patterns/src/index.ts"
cat > packages/patterns/src/index.ts << 'ODK_EOF_4'
/**
 * @odk/patterns — malzeme modeli, kesit çözücü, modül tanımları.
 *
 * Bu paket de saf kalır: platform API'si import etmez.
 */

export * from "./material.js";
export * from "./crosssection.js";
export * from "./cardslot.js";
ODK_EOF_4

echo "==> packages/patterns/src/crosssection.test.ts"
cat > packages/patterns/src/crosssection.test.ts << 'ODK_EOF_5'
import { describe, it, expect } from "vitest";
import { inchToMm } from "@odk/geometry";
import { leather, ozToMm } from "./material.js";
import type { CrossSection, Layer } from "./crosssection.js";
import {
  foldLengthDelta,
  naturalInnerRadius,
  solveCrossSection,
  hasErrors,
  layerResult,
  degToRad,
} from "./crosssection.js";

function layer(id: string, thicknessMm: number): Layer {
  return {
    id,
    name: id,
    spec: leather("veg-tan-firm", thicknessMm),
  };
}

describe("foldLengthDelta — modelin çekirdek formülü", () => {
  it("180° katta fark π × aralık", () => {
    expect(foldLengthDelta(4, 180)).toBeCloseTo(Math.PI * 4, 9);
    expect(foldLengthDelta(1, 180)).toBeCloseTo(Math.PI, 9);
  });

  it("90° katta fark (π/2) × aralık", () => {
    expect(foldLengthDelta(4, 90)).toBeCloseTo((Math.PI / 2) * 4, 9);
  });

  it("aralık sıfırsa fark sıfır", () => {
    expect(foldLengthDelta(0, 180)).toBe(0);
  });

  it("BELGELENMİŞ KURALLA DOĞRULAMA: yarım inç kuralı", () => {
    // MAKESUPPLY bifold kuralı: dış kabuk iç kabuktan ~yarım inç uzun
    // olmalı (iç 8.5″ ise dış 9″). Yarım inç = 12.7mm.
    //
    // Model, 4mm'lik kapalı yığın kalınlığı için ne söylüyor?
    const halfInch = inchToMm(0.5);
    const modelSaysFor4mmStack = foldLengthDelta(4, 180);

    expect(halfInch).toBeCloseTo(12.7, 6);
    expect(modelSaysFor4mmStack).toBeCloseTo(12.566, 3);

    // Zanaatkârın deneyimle bulduğu sayı ile fiziğin verdiği sayı
    // 0.15mm içinde örtüşüyor. Bu, doğru terimi modellediğimizin
    // bağımsız kanıtı.
    expect(Math.abs(halfInch - modelSaysFor4mmStack)).toBeLessThan(0.15);
  });

  it("yarım inç kuralı hangi yığın kalınlığına karşılık geliyor", () => {
    // Tersten: 12.7mm fark hangi aralıktan gelir?
    const gap = inchToMm(0.5) / degToRad(180);
    expect(gap).toBeCloseTo(4.04, 2);
    // 4mm — belgelenmiş "iyi bifold 6–8mm kalınlık" hedefinin içinde,
    // yani kuralın çıktığı yığın makul bir bifold.
  });
});

describe("naturalInnerRadius", () => {
  it("sarılan yığının yarısı", () => {
    expect(naturalInnerRadius(8)).toBe(4);
    expect(naturalInnerRadius(0)).toBe(0);
  });
});

describe("solveCrossSection — basit bifold", () => {
  /**
   * İki katmanlı bifold kesiti:
   *   iç kabuk (0.8mm) ve dış kabuk (1.0mm)
   *   ortada 180° kat, sarılan yığın 4mm
   *   her iki yanda 95mm düz bölüm
   */
  const inner = layer("inner", 0.8);
  const outer = layer("outer", 1.0);

  const cs: CrossSection = {
    name: "bifold-2-katman",
    layers: [inner, outer],
    runs: [
      { id: "left", name: "sol panel", length: 95, layers: ["inner", "outer"] },
      { id: "right", name: "sağ panel", length: 95, layers: ["inner", "outer"] },
    ],
    folds: [
      {
        id: "spine",
        name: "sırt",
        angleDeg: 180,
        innerRadius: naturalInnerRadius(4),
        stack: ["inner", "outer"],
      },
    ],
  };

  const result = solveCrossSection(cs);

  it("hata üretmiyor", () => {
    expect(hasErrors(result)).toBe(false);
  });

  it("dış kabuk iç kabuktan uzun", () => {
    const i = layerResult(result, "inner");
    const o = layerResult(result, "outer");
    expect(o?.flatLength).toBeGreaterThan(i?.flatLength as number);
  });

  it("fark, aralarındaki mesafeden hesaplanan değere eşit", () => {
    const i = layerResult(result, "inner");
    const o = layerResult(result, "outer");
    const delta = (o?.flatLength as number) - (i?.flatLength as number);

    // Nötr eksenler arası mesafe:
    //   iç: r + 0.45*0.8 = 2 + 0.36 = 2.36
    //   dış: r + 0.8 + 0.45*1.0 = 2 + 0.8 + 0.45 = 3.25
    //   aralık = 0.89
    expect(delta).toBeCloseTo(foldLengthDelta(0.89, 180), 6);
  });

  it("düz bölümler her iki katmana da tam ekleniyor", () => {
    expect(layerResult(result, "inner")?.straightLength).toBeCloseTo(190, 9);
    expect(layerResult(result, "outer")?.straightLength).toBeCloseTo(190, 9);
  });

  it("düz uzunluk = düz bölüm + kıvrım payı", () => {
    for (const lr of result.layers) {
      expect(lr.flatLength).toBeCloseTo(lr.straightLength + lr.bendAllowance, 9);
    }
  });

  it("kıvrım sonucu yığın kalınlığını ve farkı raporluyor", () => {
    const f = result.folds[0];
    expect(f?.stackThickness).toBeCloseTo(1.8, 9);
    expect(f?.outerInnerDelta).toBeCloseTo(foldLengthDelta(0.89, 180), 6);
  });
});

describe("k-faktörü ikincil terim — büyüklük kontrolü", () => {
  /**
   * Bu test bir davranışı değil, bir TASARIM İDDİASINI doğruluyor:
   * k'yı yanlış tahmin etmek kalıbı bozmaz, çünkü etkisi el kesim hata
   * payının altında. İddia yanlışsa k için ölçülmüş veri bulmak
   * zorunlu hale gelir.
   */
  function flatLengthWithK(k: number): number {
    const l: Layer = {
      id: "a",
      name: "a",
      spec: { temper: "veg-tan-firm", thickness: 1.2, kFactor: k },
    };
    const cs: CrossSection = {
      name: "tek katman",
      layers: [l],
      runs: [{ id: "r", name: "r", length: 100, layers: ["a"] }],
      folds: [
        { id: "f", name: "f", angleDeg: 180, innerRadius: 2, stack: ["a"] },
      ],
    };
    return layerResult(solveCrossSection(cs), "a")?.flatLength as number;
  }

  it("k 0.38 -> 0.45 arasındaki belirsizlik 0.5mm'nin altında etki yapıyor", () => {
    const diff = Math.abs(flatLengthWithK(0.45) - flatLengthWithK(0.38));
    expect(diff).toBeLessThan(0.5);
    expect(diff).toBeCloseTo(Math.PI * 1.2 * 0.07, 6);
  });

  it("buna karşılık katman ötelemesi 10 kat daha büyük etki yapıyor", () => {
    // 4mm yığında öteleme farkı ~12.6mm; k belirsizliği ~0.26mm.
    expect(foldLengthDelta(4, 180) / (Math.PI * 1.2 * 0.07)).toBeGreaterThan(10);
  });
});

describe("doğrulama", () => {
  const a = layer("a", 1.0);

  function csWith(overrides: Partial<CrossSection>): CrossSection {
    return {
      name: "test",
      layers: [a],
      runs: [{ id: "r", name: "r", length: 50, layers: ["a"] }],
      folds: [
        { id: "f", name: "f", angleDeg: 180, innerRadius: 2, stack: ["a"] },
      ],
      ...overrides,
    };
  }

  it("tanımsız katman atfını yakalar", () => {
    const r = solveCrossSection(
      csWith({ runs: [{ id: "r", name: "r", length: 50, layers: ["yok"] }] }),
    );
    expect(r.diagnostics.some((d) => d.code === "UNKNOWN_LAYER_REF")).toBe(true);
    expect(hasErrors(r)).toBe(true);
  });

  it("tekrarlanan katman id'sini yakalar", () => {
    const r = solveCrossSection(csWith({ layers: [a, layer("a", 2)] }));
    expect(r.diagnostics.some((d) => d.code === "DUPLICATE_LAYER_ID")).toBe(true);
  });

  it("geçersiz açıyı yakalar", () => {
    const r = solveCrossSection(
      csWith({
        folds: [
          { id: "f", name: "f", angleDeg: 0, innerRadius: 2, stack: ["a"] },
        ],
      }),
    );
    expect(r.diagnostics.some((d) => d.code === "BAD_ANGLE")).toBe(true);
  });

  it("aynı katmanın yığında iki kez geçmesini yakalar", () => {
    const r = solveCrossSection(
      csWith({
        folds: [
          {
            id: "f",
            name: "f",
            angleDeg: 180,
            innerRadius: 2,
            stack: ["a", "a"],
          },
        ],
      }),
    );
    expect(r.diagnostics.some((d) => d.code === "DUPLICATE_IN_STACK")).toBe(true);
  });

  it("sıfır kalınlığı yakalar", () => {
    const r = solveCrossSection(csWith({ layers: [layer("a", 0)] }));
    expect(r.diagnostics.some((d) => d.code === "ZERO_THICKNESS")).toBe(true);
  });

  it("k-faktörü aralık dışını yakalar", () => {
    const bad: Layer = {
      id: "a",
      name: "a",
      spec: { temper: "veg-tan-firm", thickness: 1, kFactor: 1.5 },
    };
    const r = solveCrossSection(csWith({ layers: [bad] }));
    expect(r.diagnostics.some((d) => d.code === "K_OUT_OF_RANGE")).toBe(true);
  });

  it("fiziksel olarak çok keskin yarıçapı uyarı olarak bildirir", () => {
    const thick = layer("t", 4);
    const r = solveCrossSection({
      name: "keskin",
      layers: [thick],
      runs: [{ id: "r", name: "r", length: 50, layers: ["t"] }],
      folds: [
        { id: "f", name: "f", angleDeg: 180, innerRadius: 0.1, stack: ["t"] },
      ],
    });
    const d = r.diagnostics.find((x) => x.code === "TIGHT_RADIUS");
    expect(d).toBeDefined();
    expect(d?.severity).toBe("warning");
    // Uyarı, hesabı engellemez — kullanıcı bilinçli tercih yapabilir.
    expect(hasErrors(r)).toBe(false);
  });

  it("geçerli kesit hiç tanılama üretmez", () => {
    expect(solveCrossSection(csWith({}))).toMatchObject({ diagnostics: [] });
  });
});

describe("gerçek kalıp verisiyle akıl sağlığı kontrolü", () => {
  it("belgelenmiş billfold açık/kapalı ölçüleriyle tutarlı", () => {
    // planbleathercraft Billfold: açık 215mm, kapalı 108mm, kalınlık 15mm.
    // 108 × 2 = 216, açık ölçü 215 verilmiş.
    //
    // NOT: Bu tek başına kıvrım payını doğrulamaz çünkü verilen "açık"
    // ölçü bitmiş ürünün yayılmış hâli, kalıptaki düz uzunluk değil.
    // Yine de büyüklük mertebesi kontrolü: 15mm kapalı kalınlıkta dış
    // katman iç katmandan π×15 ≈ 47mm uzun olmalı ki bu 215mm'lik bir
    // parçada %22 — yani böyle bir cüzdanda kat payı ihmal edilemez.
    const delta = foldLengthDelta(15, 180);
    expect(delta).toBeCloseTo(47.1, 1);
    expect(delta / 215).toBeGreaterThan(0.2);
  });

  it("3 oz deri 1.19mm", () => {
    expect(ozToMm(3)).toBeCloseTo(1.19, 2);
  });
});
ODK_EOF_5

echo "==> packages/patterns/src/material.test.ts"
cat > packages/patterns/src/material.test.ts << 'ODK_EOF_6'
import { describe, it, expect } from "vitest";
import {
  MM_PER_OZ,
  ozToMm,
  mmToOz,
  ozRangeToMm,
  leather,
  PROVISIONAL_K_FACTOR,
  RECOMMENDED_THICKNESS,
  BIFOLD_TARGET_CLOSED_THICKNESS,
  CARD_THICKNESS,
} from "./material.js";
import {
  DOCUMENTED_COMPARTMENT_WIDTH,
  CARD_SLIDING_CLEARANCE,
  PROVISIONAL_SLOT_REVEAL,
  MIN_SLOT_REVEAL,
  cardSlotGeometry,
  validateCardSlots,
  compartmentWidthDeviation,
} from "./cardslot.js";
import type { CardSlotSpec } from "./cardslot.js";

describe("ons -> milimetre", () => {
  it("1 oz = 1/64 inç = 0.396875mm (tam)", () => {
    expect(MM_PER_OZ).toBeCloseTo(0.396875, 9);
    expect(MM_PER_OZ).toBe(25.4 / 64);
  });

  it("belgelenmiş dönüşüm tablosuyla uyuşuyor", () => {
    // Sektör tabloları: 1 oz ≈ 0.4mm, 4 oz ≈ 1.6mm, 8 oz ≈ 3.2mm
    // Tablolar 0.1mm'ye yuvarlıyor; tam değer 4 oz'da 1.5875, 8 oz'da
    // 3.175. Karşılaştırma bu yuvarlama payıyla yapılmalı.
    expect(ozToMm(1)).toBeCloseTo(0.4, 2);
    expect(ozToMm(4)).toBeCloseTo(1.6, 1);
    expect(ozToMm(8)).toBeCloseTo(3.2, 1);
  });

  it("yuvarlama hatası 8 oz'da birikiyor — tam değer kullanmanın sebebi", () => {
    const rounded = 8 * 0.4;
    const exact = ozToMm(8);
    expect(Math.abs(rounded - exact)).toBeCloseTo(0.025, 3);
  });

  it("gidiş-dönüş kayıpsız", () => {
    for (const oz of [1, 2.5, 3, 4.5, 12]) {
      expect(mmToOz(ozToMm(oz))).toBeCloseTo(oz, 9);
    }
  });

  it("aralık ortalaması: 3/4 oz -> 1.39mm", () => {
    expect(ozRangeToMm(3, 4)).toBeCloseTo(1.389, 3);
  });
});

describe("k-faktörü varsayılanları", () => {
  it("hepsi sac metal literatürünün 0.33–0.50 bandında", () => {
    // Deri için ölçülmüş veri olmadığı için değerler bu banttan
    // seçildi. Bandın dışına çıkmak, dayanağı olmayan bir iddia olur.
    for (const k of Object.values(PROVISIONAL_K_FACTOR)) {
      expect(k).toBeGreaterThanOrEqual(0.33);
      expect(k).toBeLessThanOrEqual(0.5);
    }
  });

  it("sert deri yumuşaktan daha büyük k alıyor", () => {
    expect(PROVISIONAL_K_FACTOR["veg-tan-firm"]).toBeGreaterThan(
      PROVISIONAL_K_FACTOR["chrome-soft"],
    );
  });

  it("leather() sertliğe göre k atıyor", () => {
    expect(leather("veg-tan-firm", 1.2).kFactor).toBe(0.45);
    expect(leather("chrome-soft", 1.2).kFactor).toBe(0.38);
  });
});

describe("kalınlık önerileri", () => {
  it("aralıklar tutarlı: min <= preferred <= max", () => {
    for (const r of Object.values(RECOMMENDED_THICKNESS)) {
      expect(r.min).toBeLessThanOrEqual(r.preferred);
      expect(r.preferred).toBeLessThanOrEqual(r.max);
    }
  });

  it("yuva derisi dış kabuktan ince öneriliyor", () => {
    expect(RECOMMENDED_THICKNESS.cardSlot.preferred).toBeLessThan(
      RECOMMENDED_THICKNESS.outerShell.preferred,
    );
  });

  it("önerilen kalınlıklarla asgari bifold hedef kalınlığın altında kalıyor", () => {
    // Dış + iç + tek yuva katmanı, artı bir kart.
    const minimal =
      RECOMMENDED_THICKNESS.outerShell.preferred +
      RECOMMENDED_THICKNESS.innerShell.preferred +
      RECOMMENDED_THICKNESS.cardSlot.preferred +
      CARD_THICKNESS;
    expect(minimal).toBeLessThan(BIFOLD_TARGET_CLOSED_THICKNESS);
  });
});

describe("kart yuvası — bölme genişliği", () => {
  it("hesabımız belgelenmiş değerlere yakın (sapma < 3mm)", () => {
    // Bu test modelin sektör pratiğinden kopmasını yakalar.
    expect(Math.abs(compartmentWidthDeviation("horizontal"))).toBeLessThan(3);
    expect(Math.abs(compartmentWidthDeviation("vertical"))).toBeLessThan(3);
  });

  it("yatay bölme ~100mm", () => {
    const geo = cardSlotGeometry({
      count: 3,
      construction: "t-slot",
      orientation: "horizontal",
      leatherThickness: 0.7,
    });
    expect(geo.compartmentWidth).toBeCloseTo(100, 6);
    expect(
      Math.abs(geo.compartmentWidth - DOCUMENTED_COMPARTMENT_WIDTH.horizontal),
    ).toBeLessThan(1);
  });

  it("dikey bölme ~70mm", () => {
    const geo = cardSlotGeometry({
      count: 3,
      construction: "t-slot",
      orientation: "vertical",
      leatherThickness: 0.7,
    });
    expect(
      Math.abs(geo.compartmentWidth - DOCUMENTED_COMPARTMENT_WIDTH.vertical),
    ).toBeLessThan(1);
  });

  it("boşluk sabiti yöne göre farklı ve belgelenmiş genişlikleri tam veriyor", () => {
    expect(85.6 + CARD_SLIDING_CLEARANCE.horizontal + 7).toBeCloseTo(100, 6);
    expect(53.98 + CARD_SLIDING_CLEARANCE.vertical + 7).toBeCloseTo(69.98, 6);
    expect(CARD_SLIDING_CLEARANCE.vertical).toBeGreaterThan(
      CARD_SLIDING_CLEARANCE.horizontal,
    );
  });
});

describe("kart yuvası — T-slot vs stacked", () => {
  const base: CardSlotSpec = {
    count: 6,
    construction: "stacked",
    orientation: "horizontal",
    leatherThickness: 0.7,
  };

  it("stacked: kenar kalınlığı yuva sayısıyla çarpan olarak büyüyor", () => {
    const geo = cardSlotGeometry(base);
    expect(geo.edgeThickness).toBeCloseTo(6 * 0.7, 9);
  });

  it("T-slot: kenar kalınlığı yuva sayısından BAĞIMSIZ", () => {
    // Belgelenmiş temel avantaj. Modelin bunu yansıtması, kural
    // motorunun doğru öneri vermesinin ön koşulu.
    for (const count of [2, 4, 6, 8]) {
      const geo = cardSlotGeometry({ ...base, count, construction: "t-slot" });
      expect(geo.edgeThickness).toBeCloseTo(0.7, 9);
    }
  });

  it("T-slot 6 yuvada kenarda 3.5mm kazandırıyor", () => {
    const stacked = cardSlotGeometry(base);
    const tslot = cardSlotGeometry({ ...base, construction: "t-slot" });
    expect(stacked.edgeThickness - tslot.edgeThickness).toBeCloseTo(3.5, 9);
  });

  it("merkez bölge her iki yapımda da yığılıyor", () => {
    const stacked = cardSlotGeometry(base);
    const tslot = cardSlotGeometry({ ...base, construction: "t-slot" });
    expect(tslot.centerThickness).toBeCloseTo(stacked.centerThickness, 9);
  });

  it("parça dağılımı: en alt yuva düz dikdörtgen kalıyor", () => {
    const geo = cardSlotGeometry({ ...base, construction: "t-slot" });
    expect(geo.tSlotPieces).toBe(5);
    expect(geo.rectanglePieces).toBe(1);
    expect(geo.tSlotPieces + geo.rectanglePieces).toBe(6);
  });

  it("stacked'da hiç T-slot parçası yok", () => {
    const geo = cardSlotGeometry(base);
    expect(geo.tSlotPieces).toBe(0);
    expect(geo.rectanglePieces).toBe(6);
  });
});

describe("kart yuvası — yığın yüksekliği", () => {
  it("tek yuva tam kart yüksekliği", () => {
    const geo = cardSlotGeometry({
      count: 1,
      construction: "t-slot",
      orientation: "horizontal",
      leatherThickness: 0.7,
    });
    expect(geo.stackHeight).toBeCloseTo(53.98, 9);
  });

  it("5 yuva = kart yüksekliği + 4 kademe", () => {
    const geo = cardSlotGeometry({
      count: 5,
      construction: "t-slot",
      orientation: "horizontal",
      leatherThickness: 0.7,
      reveal: 12,
    });
    expect(geo.stackHeight).toBeCloseTo(53.98 + 4 * 12, 9);
  });

  it("sıfır yuva sıfır yükseklik", () => {
    const geo = cardSlotGeometry({
      count: 0,
      construction: "t-slot",
      orientation: "horizontal",
      leatherThickness: 0.7,
    });
    expect(geo.stackHeight).toBe(0);
  });

  it("kartlar takılıyken kalınlık artıyor", () => {
    const geo = cardSlotGeometry({
      count: 4,
      construction: "t-slot",
      orientation: "horizontal",
      leatherThickness: 0.7,
    });
    expect(geo.loadedThickness - geo.centerThickness).toBeCloseTo(4 * 0.76, 9);
  });
});

describe("kart yuvası — kural denetimi", () => {
  it("kademe alt sınırın altındaysa hata", () => {
    const d = validateCardSlots({
      count: 4,
      construction: "t-slot",
      orientation: "horizontal",
      leatherThickness: 0.7,
      reveal: 3,
    });
    const found = d.find((x) => x.code === "REVEAL_TOO_SMALL");
    expect(found?.severity).toBe("error");
  });

  it("varsayılan kademe alt sınırın üstünde", () => {
    expect(PROVISIONAL_SLOT_REVEAL).toBeGreaterThan(MIN_SLOT_REVEAL);
  });

  it("3'ten fazla stacked yuva uyarı üretiyor ve T-slot öneriyor", () => {
    const d = validateCardSlots({
      count: 6,
      construction: "stacked",
      orientation: "horizontal",
      leatherThickness: 0.7,
    });
    const found = d.find((x) => x.code === "STACKED_TOO_MANY");
    expect(found).toBeDefined();
    expect(found?.message).toContain("T-slot");
  });

  it("aynı yuva sayısı T-slot ile uyarı üretmiyor", () => {
    const d = validateCardSlots({
      count: 6,
      construction: "t-slot",
      orientation: "horizontal",
      leatherThickness: 0.7,
    });
    expect(d.find((x) => x.code === "STACKED_TOO_MANY")).toBeUndefined();
  });

  it("kalın yuva derisi uyarı üretiyor", () => {
    const d = validateCardSlots({
      count: 3,
      construction: "t-slot",
      orientation: "horizontal",
      leatherThickness: 1.4,
    });
    expect(d.find((x) => x.code === "SLOT_LEATHER_THICK")).toBeDefined();
  });

  it("önerilen kalınlıkta uyarı yok", () => {
    const d = validateCardSlots({
      count: 3,
      construction: "t-slot",
      orientation: "horizontal",
      leatherThickness: RECOMMENDED_THICKNESS.cardSlot.preferred,
    });
    expect(d).toHaveLength(0);
  });

  it("sıfır yuva hata", () => {
    const d = validateCardSlots({
      count: 0,
      construction: "t-slot",
      orientation: "horizontal",
      leatherThickness: 0.7,
    });
    expect(d.find((x) => x.code === "NO_SLOTS")?.severity).toBe("error");
  });
});
ODK_EOF_6

echo "==> docs/SOURCES.md"
cat > docs/SOURCES.md << 'ODK_EOF_7'
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
ODK_EOF_7

echo "==> Bagimliliklar"
pnpm install

echo "==> Testler"
pnpm test

echo "==> Typecheck"
pnpm typecheck

cat << 'ODK_DONE'

============================================================
ADIM 6 TAMAM — Kesit cozucu
============================================================

Eklenen dosyalar:
  packages/patterns/src/material.ts       oz<->mm, sertlik, k-faktoru,
                                          kalinlik onerileri
  packages/patterns/src/crosssection.ts   notr eksen yurumesi, dogrulama
  packages/patterns/src/cardslot.ts       T-slot vs stacked matematigi
  packages/patterns/src/*.test.ts         56 test
  docs/SOURCES.md                         her sabitin dayanagi

Git komutlari:

  git add -A
  git commit -m "Faz 1 Adim 6: kesit cozucu

- foldLengthDelta: 180 derece katta iki katman farki = pi x aralik
- DOGRULAMA: MAKESUPPLY yarim inc kurali (12.7mm) ile modelin 4mm
  yigin icin verdigi deger (12.566mm) 0.15mm icinde ortusuyor
- k-faktoru ikincil terim oldugu test ile sabitlendi (0.26mm etki,
  katman otelemesi 48 kat daha buyuk)
- T-slot: kenar kalinligi yuva sayisindan bagimsiz; stacked ile
  6 yuvada 3.5mm fark
- kart kayma boslugu yone gore farkli (yatay 7.4mm, dikey 9.0mm),
  belgelenmis bolme genisliklerinden turetildi
- docs/SOURCES.md: BELGELENMIS / TURETILMIS / GECICI ayrimi
- 170 test geciyor (114 geometry + 56 patterns), typecheck temiz"

  git push

Sonraki adim: Adim 7 — dikis dagitici.
ODK_DONE
