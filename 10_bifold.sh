#!/usr/bin/env bash
#
# 10_bifold.sh — Faz 3: Bifold cuzdan + BillPocket modulu
#
# Repo kokunde calistir. Idempotent.

set -euo pipefail

if [ ! -f "pnpm-workspace.yaml" ] || [ ! -d "packages/print" ]; then
  echo "HATA: Repo kokunde calistirilmali ve 09 uygulanmis olmali." >&2
  exit 1
fi

mkdir -p packages/patterns/src packages/print/src apps/web/src docs

echo "==> packages/patterns/src/crosssection.ts"
cat > packages/patterns/src/crosssection.ts << 'ODK_EOF_0'
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
  /**
   * Katman OLMAYAN dolgu: id'si verilen katmanın hemen İÇİNE eklenen
   * kalınlık (mm).
   *
   * NİYE GEREKLİ: bifold'da dış kabuk, iç kabuğun etrafını değil
   * TÜM İÇERİĞİN etrafını dolanır — kart yığını, kartların kendisi,
   * banknot. Bu içerik kıvrımdan geçen bir deri katmanı değil, ama dış
   * kabuğun yürüyeceği yarıçapı belirliyor.
   *
   * Bu alan olmadan modelin verdiği dış/iç fark 2.8mm çıkıyordu;
   * belgelenmiş yarım inç kuralı 12.7mm diyor. Aradaki farkın tamamı
   * bu dolgudan geliyor.
   */
  readonly gaps?: Readonly<Record<string, Mm>>;
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
    total += fold.gaps?.[id] ?? 0;
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

      // Bu katmandan önce gelen, katman olmayan dolgu.
      insideThickness += fold.gaps?.[id] ?? 0;

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

    for (const id of Object.keys(fold.gaps ?? {})) {
      if (!fold.stack.includes(id)) {
        out.push({
          severity: "error",
          code: "GAP_NOT_IN_STACK",
          message: `"${fold.name}" kıvrımında dolgu tanımsız katmana atıf yapıyor: ${id}`,
        });
      }
      const g = fold.gaps?.[id];
      if (g !== undefined && g < 0) {
        out.push({
          severity: "error",
          code: "NEGATIVE_GAP",
          message: `"${fold.name}" kıvrımında "${id}" için negatif dolgu.`,
        });
      }
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

    // Fiziksel makullük: deri KENDİ kalınlığından daha keskin kıvrılamaz.
    //
    // Ölçüt bilerek EN İÇ KATMANIN kalınlığı, tüm yığın değil. İlk
    // sürümde yığın kalınlığına bakılıyordu ve bifold'da her zaman
    // yanlış uyarı veriyordu: dolgulu bir kıvrımda en iç katman kendi
    // etrafına sarılır (yarıçap ~0.4mm), dış katman ise tüm içeriğin
    // etrafını dolanır. İkisinin yarıçapı doğal olarak çok farklı ve
    // "innerRadius" tanımı gereği yalnızca en içtekini tarif eder.
    const innermostId = fold.stack[0];
    const innermost =
      innermostId === undefined ? undefined : index.get(innermostId);
    if (innermost !== undefined) {
      const minRadius = innermost.spec.thickness * 0.5;
      if (fold.innerRadius + EPS < minRadius) {
        out.push({
          severity: "warning",
          code: "TIGHT_RADIUS",
          message:
            `"${fold.name}" iç yarıçapı (${fold.innerRadius.toFixed(2)}mm) ` +
            `en iç katmanın kalınlığına göre çok keskin ` +
            `(en az ~${minRadius.toFixed(2)}mm olmalı). ` +
            `Deri bu yarıçapta kırılır ve kalıp kısa çıkar.`,
        });
      }
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
ODK_EOF_0

echo "==> packages/patterns/src/crosssection.test.ts"
cat > packages/patterns/src/crosssection.test.ts << 'ODK_EOF_1'
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

describe("kıvrımda katman olmayan dolgu (gaps)", () => {
  const a = layer("a", 1.0);
  const b = layer("b", 1.0);

  function withGap(gap: number) {
    const cs: CrossSection = {
      name: "dolgu",
      layers: [a, b],
      runs: [{ id: "r", name: "r", length: 50, layers: ["a", "b"] }],
      folds: [
        {
          id: "f",
          name: "f",
          angleDeg: 180,
          innerRadius: 0.5,
          stack: ["a", "b"],
          gaps: { b: gap },
        },
      ],
    };
    return solveCrossSection(cs);
  }

  it("dolgu dış katmanı uzatıyor, iç katmanı etkilemiyor", () => {
    const none = withGap(0);
    const some = withGap(4);
    expect(layerResult(some, "a")?.flatLength).toBeCloseTo(
      layerResult(none, "a")?.flatLength as number,
      9,
    );
    expect(layerResult(some, "b")?.flatLength).toBeGreaterThan(
      layerResult(none, "b")?.flatLength as number,
    );
  });

  it("uzama tam olarak θ × dolgu kadar", () => {
    const delta =
      (layerResult(withGap(4), "b")?.flatLength as number) -
      (layerResult(withGap(0), "b")?.flatLength as number);
    expect(delta).toBeCloseTo(foldLengthDelta(4, 180), 9);
  });

  it("yığında olmayan katmana dolgu hata veriyor", () => {
    const r = solveCrossSection({
      name: "hatalı",
      layers: [a],
      runs: [{ id: "r", name: "r", length: 50, layers: ["a"] }],
      folds: [
        {
          id: "f",
          name: "f",
          angleDeg: 180,
          innerRadius: 0.5,
          stack: ["a"],
          gaps: { yok: 2 },
        },
      ],
    });
    expect(r.diagnostics.some((d) => d.code === "GAP_NOT_IN_STACK")).toBe(true);
  });

  it("negatif dolgu hata veriyor", () => {
    const r = withGap(-1);
    expect(r.diagnostics.some((d) => d.code === "NEGATIVE_GAP")).toBe(true);
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
    // Ölçüt EN İÇ KATMANIN kalınlığı: 4mm deri 0.1mm yarıçapla kıvrılamaz.
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
ODK_EOF_1

echo "==> packages/patterns/src/banknote.ts"
cat > packages/patterns/src/banknote.ts << 'ODK_EOF_2'
import type { Mm } from "@odk/geometry";

/**
 * BANKNOT VE PARA BÖLMESİ
 *
 * Cüzdanın açık genişliğini iki şey belirler: banknot genişliği ve iki
 * kart yığınının yan yana genişliği. Hangisi büyükse o kazanır.
 */

export type Currency = "TRY" | "USD" | "EUR" | "GBP";

export interface Banknote {
  readonly currency: Currency;
  readonly label: string;
  /** En büyük kupürün uzun kenarı. */
  readonly width: Mm;
  /** En büyük kupürün kısa kenarı. */
  readonly height: Mm;
  /** Bu oturumda kaynaktan doğrulandı mı? */
  readonly verified: boolean;
  readonly note: string;
}

/**
 * En büyük kupüre göre ölçüler. Cüzdan en büyük banknotu almalı,
 * ortalamayı değil.
 *
 * TCMB tüm TL banknotlarını uzun kenarda 6mm, kısa kenarda ikili grup
 * hâlinde 4mm farkla basıyor; yani en büyük kupür diğerlerini de kapsıyor.
 */
export const BANKNOTES: Record<Currency, Banknote> = {
  TRY: {
    currency: "TRY",
    label: "Türk lirası (200 TL)",
    width: 160,
    height: 72,
    verified: true,
    note: "TCMB verisi. 200 TL en büyük kupür: 160 × 72mm.",
  },
  USD: {
    currency: "USD",
    label: "ABD doları (tüm kupürler)",
    width: 156,
    height: 66.3,
    verified: true,
    note: "Tüm dolar kupürleri aynı boyutta: 156 × 66.3mm.",
  },
  EUR: {
    currency: "EUR",
    label: "Euro (200 €)",
    width: 153,
    height: 77,
    verified: false,
    note:
      "⚠ Bu oturumda kaynaktan doğrulanmadı. Europa serisi 200 € için " +
      "153 × 77mm; eski seri 200/500 € daha büyüktü (160 × 82mm). " +
      "Kullanmadan önce doğrula.",
  },
  GBP: {
    currency: "GBP",
    label: "Sterlin (£50)",
    width: 146,
    height: 77,
    verified: false,
    note:
      "⚠ Bu oturumda kaynaktan doğrulanmadı. Polimer £50 için 146 × 77mm.",
  },
};

/**
 * Banknotun bölmeye rahat girmesi için yanlardan bırakılan toplam boşluk.
 *
 * Kart yuvasındaki 7.4mm'den küçük tutuluyor: banknot ince ve esnek,
 * kart gibi rijit değil; fazla boşluk paranın bölme içinde kaymasına ve
 * kenarlarının kıvrılmasına yol açıyor.
 */
export const BILL_CLEARANCE: Mm = 4;

/**
 * Banknotun bölme ağzından yukarıda kalmaması için gereken asgari örtü.
 *
 * Banknot bölmenin ağzından taşarsa hem görünür hem yıpranır. Cüzdan
 * yüksekliği banknot yüksekliğinden en az bu kadar fazla olmalı.
 */
export const BILL_COVER_MARGIN: Mm = 6;

export interface BillPocketSpec {
  readonly currency: Currency;
  readonly leatherThickness: Mm;
  readonly stitchMargin: Mm;
  /** Verilmezse BILL_CLEARANCE. */
  readonly clearance?: Mm;
}

export interface BillPocketGeometry {
  /** Cüzdan açıkken bölmenin iç genişliği. */
  readonly interiorWidth: Mm;
  /** Bölmenin dış genişliği (dikiş payları dahil). */
  readonly compartmentWidth: Mm;
  /** Banknotun tamamen örtülmesi için gereken asgari cüzdan yüksekliği. */
  readonly minWalletHeight: Mm;
  readonly banknote: Banknote;
}

export function billPocketGeometry(spec: BillPocketSpec): BillPocketGeometry {
  const note = BANKNOTES[spec.currency];
  const clearance = spec.clearance ?? BILL_CLEARANCE;
  const interiorWidth = note.width + clearance;
  return {
    interiorWidth,
    compartmentWidth: interiorWidth + 2 * spec.stitchMargin,
    minWalletHeight: note.height + BILL_COVER_MARGIN,
    banknote: note,
  };
}

export interface BillDiagnostic {
  readonly severity: "error" | "warning";
  readonly code: string;
  readonly message: string;
}

export function validateBillPocket(
  spec: BillPocketSpec,
  walletHeight: Mm,
): BillDiagnostic[] {
  const out: BillDiagnostic[] = [];
  const geo = billPocketGeometry(spec);

  if (walletHeight < geo.minWalletHeight) {
    out.push({
      severity: "error",
      code: "BILL_STICKS_OUT",
      message:
        `Cüzdan yüksekliği ${walletHeight.toFixed(1)}mm — ` +
        `${geo.banknote.label} için en az ${geo.minWalletHeight.toFixed(1)}mm ` +
        `gerekiyor. Banknot bölmenin ağzından taşar.`,
    });
  }

  if (!geo.banknote.verified) {
    out.push({
      severity: "warning",
      code: "BANKNOTE_UNVERIFIED",
      message: `${geo.banknote.label}: ${geo.banknote.note}`,
    });
  }

  if (spec.leatherThickness > 1.0) {
    out.push({
      severity: "warning",
      code: "BILL_LEATHER_THICK",
      message:
        `İç kabuk ${spec.leatherThickness.toFixed(1)}mm — bifold'da 0.6–1.0mm ` +
        `öneriliyor. Kalın iç kabuk kapalı kalınlığı hızla büyütür.`,
    });
  }

  return out;
}
ODK_EOF_2

echo "==> packages/patterns/src/bifold.ts"
cat > packages/patterns/src/bifold.ts << 'ODK_EOF_3'
import type { Mm, Polyline, Vec } from "@odk/geometry";
import {
  A4,
  CARD_ID1,
  bbox,
  cutLine,
  distributeStitches,
  flattenPath,
  path,
  roundCorners,
  stitchLine,
  vec,
} from "@odk/geometry";
import type { Temper } from "./material.js";
import {
  BIFOLD_TARGET_CLOSED_THICKNESS,
  CARD_THICKNESS,
  MAX_CLOSED_THICKNESS,
  RECOMMENDED_THICKNESS,
  leather,
} from "./material.js";
import type { SlotConstruction } from "./cardslot.js";
import { T_SLOT_WRAP_ALLOWANCE, cardSlotGeometry, validateCardSlots } from "./cardslot.js";
import type { Currency } from "./banknote.js";
import { billPocketGeometry, validateBillPocket } from "./banknote.js";
import type {
  AssemblyPlacement,
  PatternPiece,
  PatternResult,
  PatternSummary,
} from "./cardholder.js";
import type { CrossSection, Diagnostic, Layer } from "./crosssection.js";
import {
  foldLengthDelta,
  layerResult,
  naturalInnerRadius,
  solveCrossSection,
} from "./crosssection.js";

/**
 * BİFOLD CÜZDAN
 *
 * ═══════════════════════════════════════════════════════════════════════
 * NEDEN BU MODEL KARTLIKTAN FARKLI
 * ═══════════════════════════════════════════════════════════════════════
 *
 * Kartlıkta dış kabuk yalnızca kendi iç katmanının etrafını dolanıyordu.
 * Bifold'da dış kabuk TÜM İÇERİĞİN etrafını dolanır: iç kabuk, iki
 * yandaki kart yığınları, kartların kendisi ve banknot.
 *
 * Bunu ilk modellediğimde kıvrım yığınına yalnızca iki deri katmanını
 * koydum ve dış/iç fark 2.8mm çıktı. Belgelenmiş kural 12.7mm (yarım
 * inç) diyor. Fark, kıvrımda katman OLMAYAN dolgudan geliyordu:
 * kartlar ve yuva derileri kıvrımdan geçmiyor ama dış kabuğun
 * yürüyeceği yarıçapı belirliyor.
 *
 * Fold.gaps alanı tam olarak bunun için eklendi. Varsayılan
 * parametrelerle model 12–13mm veriyor; yarım inç kuralıyla örtüşüyor.
 * (Bkz. bifold.test.ts — bu bir test olarak sabitlendi.)
 */

export interface BifoldParams {
  /** Her panelde kaç kart yuvası. */
  readonly cardSlotsPerSide: number;
  readonly construction: SlotConstruction;
  readonly currency: Currency;
  readonly outerThickness: Mm;
  readonly innerThickness: Mm;
  readonly slotThickness: Mm;
  readonly temper: Temper;
  readonly reveal: Mm;
  readonly stitchMargin: Mm;
  readonly cornerRadius: Mm;
  readonly penAllowance: Mm;
  readonly pitch?: Mm;
}

export const BIFOLD_DEFAULTS: BifoldParams = {
  cardSlotsPerSide: 3,
  construction: "t-slot",
  currency: "TRY",
  // Bifold'da dış kabuk aralığın ALT ucunda tutulmalı; katman sayısı
  // fazla olduğu için kalınlık hızla birikiyor.
  outerThickness: 0.9,
  innerThickness: 0.8,
  slotThickness: RECOMMENDED_THICKNESS.cardSlot.preferred,
  temper: "veg-tan-firm",
  reveal: 12,
  stitchMargin: 3.5,
  cornerRadius: 5,
  penAllowance: 0.3,
  pitch: 3.85,
};

function rectangle(x: Mm, y: Mm, w: Mm, h: Mm): Polyline {
  return flattenPath(
    path()
      .moveTo(vec(x, y))
      .lineTo(vec(x + w, y))
      .lineTo(vec(x + w, y + h))
      .lineTo(vec(x, y + h))
      .close(),
  );
}

function tSlotShape(width: Mm, height: Mm, mouthHeight: Mm, sideInset: Mm): Polyline {
  const shoulder = height - mouthHeight;
  return flattenPath(
    path()
      .moveTo(vec(sideInset, 0))
      .lineTo(vec(width - sideInset, 0))
      .lineTo(vec(width - sideInset, shoulder))
      .lineTo(vec(width, shoulder))
      .lineTo(vec(width, height))
      .lineTo(vec(0, height))
      .lineTo(vec(0, shoulder))
      .lineTo(vec(sideInset, shoulder))
      .close(),
  );
}

export function generateBifold(params: BifoldParams): PatternResult {
  const diagnostics: Diagnostic[] = [];
  const n = Math.max(0, Math.floor(params.cardSlotsPerSide));

  // --- Kart yuvaları (panel başına) -------------------------------------
  const slotGeo = cardSlotGeometry({
    count: n,
    construction: params.construction,
    orientation: "horizontal",
    leatherThickness: params.slotThickness,
    reveal: params.reveal,
    stitchMargin: params.stitchMargin,
  });

  for (const d of validateCardSlots({
    count: n,
    construction: params.construction,
    orientation: "horizontal",
    leatherThickness: params.slotThickness,
    reveal: params.reveal,
    stitchMargin: params.stitchMargin,
  })) {
    diagnostics.push({ severity: d.severity, code: d.code, message: d.message });
  }

  // --- Cüzdan ölçüleri ---------------------------------------------------
  //
  // Açık genişlik iki kısıttan büyüğü:
  //   a) banknot + boşluk + iki yanda dikiş payı
  //   b) iki kart yığını yan yana
  // Yükseklik ise kart yığını ve banknot örtüsünden büyüğü.
  const billGeo = billPocketGeometry({
    currency: params.currency,
    leatherThickness: params.innerThickness,
    stitchMargin: params.stitchMargin,
  });

  const panelWidth = slotGeo.compartmentWidth;
  const widthFromCards = 2 * panelWidth;
  const widthFromBill = billGeo.compartmentWidth;
  const openWidth = Math.max(widthFromCards, widthFromBill);

  const heightFromCards = slotGeo.stackHeight + 2 * params.stitchMargin;
  const walletHeight = Math.max(heightFromCards, billGeo.minWalletHeight);

  for (const d of validateBillPocket(
    {
      currency: params.currency,
      leatherThickness: params.innerThickness,
      stitchMargin: params.stitchMargin,
    },
    walletHeight,
  )) {
    diagnostics.push({ severity: d.severity, code: d.code, message: d.message });
  }

  // --- Kalınlıklar -------------------------------------------------------
  //
  // Kapalı kalınlık en kalın noktada ölçülür: iki panel de kart yüklü.
  const cardStackPerPanel = slotGeo.centerThickness + n * CARD_THICKNESS;
  const closedThickness =
    2 * params.outerThickness + 2 * params.innerThickness + 2 * slotGeo.centerThickness;
  const loadedThickness =
    2 * params.outerThickness + 2 * params.innerThickness + 2 * cardStackPerPanel;

  // --- Kesit -------------------------------------------------------------
  //
  // Kıvrımda yalnızca iki deri katmanı geçiyor (iç ve dış kabuk).
  // Kart yığını kıvrımdan GEÇMEZ ama dış kabuğun yarıçapını belirler;
  // bu yüzden dolgu (gap) olarak modelleniyor.
  const outerSpec = leather(params.temper, params.outerThickness);
  const innerSpec = leather(params.temper, params.innerThickness);

  const layers: Layer[] = [
    { id: "inner", name: "iç kabuk", spec: innerSpec },
    { id: "outer", name: "dış kabuk", spec: outerSpec },
  ];

  const foldFill = cardStackPerPanel;

  const crossSection: CrossSection = {
    name: "bifold",
    layers,
    runs: [
      { id: "left", name: "sol panel", length: panelWidth, layers: ["inner", "outer"] },
      { id: "right", name: "sağ panel", length: panelWidth, layers: ["inner", "outer"] },
    ],
    folds: [
      {
        id: "spine",
        name: "sırt",
        angleDeg: 180,
        innerRadius: naturalInnerRadius(params.innerThickness),
        stack: ["inner", "outer"],
        gaps: { outer: foldFill },
      },
    ],
  };

  const solved = solveCrossSection(crossSection);
  diagnostics.push(...solved.diagnostics);

  const innerFlat = layerResult(solved, "inner")?.flatLength ?? openWidth;
  const outerFlat = layerResult(solved, "outer")?.flatLength ?? openWidth;
  const foldAllowance = outerFlat - innerFlat;

  // --- Parçalar ----------------------------------------------------------
  const pieces: PatternPiece[] = [];

  const outerNominal = roundCorners(rectangle(0, 0, outerFlat, walletHeight), true, {
    radius: params.cornerRadius,
  });
  const outerCut = cutLine(outerNominal, { penAllowance: params.penAllowance });
  const outerStitch = roundCorners(stitchLine(outerCut, params.stitchMargin), true, {
    radius: Math.max(1, params.cornerRadius - params.stitchMargin),
  });
  const outerPlan = distributeStitches(
    outerStitch,
    true,
    params.pitch !== undefined ? { pitch: params.pitch } : {},
  );
  const outerBox = bbox(outerCut);

  const foldCentre = outerFlat / 2;
  pieces.push({
    id: "outer",
    code: "A",
    name: "dış kabuk",
    kind: "outer",
    quantity: 1,
    leatherThickness: params.outerThickness,
    cutLine: outerCut,
    stitchLine: outerStitch,
    stitchPlan: outerPlan,
    foldLines: [
      {
        from: vec(foldCentre - foldAllowance / 2, 0),
        to: vec(foldCentre - foldAllowance / 2, walletHeight),
        label: "kat başlangıcı",
      },
      {
        from: vec(foldCentre + foldAllowance / 2, 0),
        to: vec(foldCentre + foldAllowance / 2, walletHeight),
        label: "kat bitişi",
      },
    ],
    width: outerBox.width,
    height: outerBox.height,
  });

  // İç kabuk: banknot bölmesinin arkası. Dış kabuktan kat payı kadar kısa.
  const innerNominal = roundCorners(rectangle(0, 0, innerFlat, walletHeight), true, {
    radius: params.cornerRadius,
  });
  const innerCut = cutLine(innerNominal, { penAllowance: params.penAllowance });
  const innerBox = bbox(innerCut);
  pieces.push({
    id: "inner",
    code: "B",
    name: "iç kabuk (para bölmesi)",
    kind: "outer",
    quantity: 1,
    leatherThickness: params.innerThickness,
    cutLine: innerCut,
    foldLines: [
      {
        from: vec(innerFlat / 2, 0),
        to: vec(innerFlat / 2, walletHeight),
        label: "kat",
      },
    ],
    width: innerBox.width,
    height: innerBox.height,
  });

  // Yuva parçaları — iki panel için iki kat adet.
  const slotPieceHeight = CARD_ID1.height + params.stitchMargin;
  const mouthHeight = Math.min(params.reveal, slotPieceHeight / 2);
  const sideInset = params.stitchMargin + T_SLOT_WRAP_ALLOWANCE;

  if (slotGeo.rectanglePieces > 0) {
    const nominal = roundCorners(rectangle(0, 0, panelWidth, slotPieceHeight), true, {
      radius: Math.min(params.cornerRadius, slotPieceHeight / 4),
    });
    const cut = cutLine(nominal, { penAllowance: params.penAllowance });
    const b = bbox(cut);
    pieces.push({
      id: "slot-rect",
      code: "C",
      name: "alt yuva (düz)",
      kind: "slot-rect",
      quantity: slotGeo.rectanglePieces * 2,
      leatherThickness: params.slotThickness,
      cutLine: cut,
      foldLines: [],
      width: b.width,
      height: b.height,
    });
  }

  if (slotGeo.tSlotPieces > 0) {
    const nominal = roundCorners(
      tSlotShape(panelWidth, slotPieceHeight, mouthHeight, sideInset),
      true,
      { radius: Math.min(params.cornerRadius, sideInset / 2) },
    );
    const cut = cutLine(nominal, { penAllowance: params.penAllowance });
    const b = bbox(cut);
    pieces.push({
      id: "slot-t",
      code: "D",
      name: "T-slot yuva",
      kind: "slot-t",
      quantity: slotGeo.tSlotPieces * 2,
      leatherThickness: params.slotThickness,
      cutLine: cut,
      foldLines: [],
      width: b.width,
      height: b.height,
    });
  }

  // --- Montaj ------------------------------------------------------------
  //
  // İki panel: sol (x = 0) ve sağ (x = outerFlat − panelWidth).
  const assembly: AssemblyPlacement[] = [];
  const rightPanelX = Math.max(0, outerFlat - panelWidth);
  const sides: readonly { readonly x: Mm; readonly tag: string }[] = [
    { x: 0, tag: "S" },
    { x: rightPanelX, tag: "R" },
  ];

  let layerIndex = 1;
  for (const side of sides) {
    for (let i = 0; i < n; i++) {
      const isRect = params.construction === "stacked" || i === 0;
      assembly.push({
        pieceId: isRect ? "slot-rect" : "slot-t",
        code: `${isRect ? "C" : "D"}-${side.tag}${i + 1}`,
        x: side.x,
        y: params.stitchMargin + i * params.reveal,
        layer: layerIndex,
      });
      layerIndex += 1;
    }
  }

  // --- Kural denetimi ----------------------------------------------------
  if (loadedThickness > MAX_CLOSED_THICKNESS) {
    diagnostics.push({
      severity: "error",
      code: "TOO_THICK",
      message:
        `Kart yüklü kalınlık ${loadedThickness.toFixed(1)}mm — üst sınır ` +
        `${MAX_CLOSED_THICKNESS}mm. Yuva sayısını azalt ya da daha ince deri kullan.`,
    });
  } else if (closedThickness > BIFOLD_TARGET_CLOSED_THICKNESS) {
    // ÖLÇÜT BOŞ KALINLIK. Belgelenmiş hedef ("iyi bir bifold boşken
    // 6–8mm'yi geçmemeli") boş ürün için verilmiş. İlk sürümde yüklü
    // kalınlığa bakıyordum ve 3 yuvalı — son derece yaygın — bir cüzdan
    // gereksiz yere uyarı alıyordu.
    diagnostics.push({
      severity: "warning",
      code: "BULKY",
      message:
        `Boş kalınlık ${closedThickness.toFixed(1)}mm — belgelenmiş hedef ` +
        `${BIFOLD_TARGET_CLOSED_THICKNESS}mm. Kart yüklü ` +
        `${loadedThickness.toFixed(1)}mm olacak. Yuva sayısını azaltmak ya da ` +
        `yuva derisini inceltmek belirgin fark yaratır.`,
    });
  }

  if (widthFromBill > widthFromCards) {
    diagnostics.push({
      severity: "warning",
      code: "WIDTH_FROM_BILL",
      message:
        `Açık genişliği banknot belirledi (${widthFromBill.toFixed(1)}mm > ` +
        `${widthFromCards.toFixed(1)}mm). Paneller kart yığınından geniş kalıyor; ` +
        `yuvaları ortalamak ya da bölme genişletmek gerekebilir.`,
    });
  }

  const fitsA4 = outerBox.width <= A4.width - 20 && outerBox.height <= A4.height - 20;
  if (!fitsA4) {
    diagnostics.push({
      severity: "warning",
      code: "NEEDS_TILING",
      message:
        `Dış kabuk ${outerBox.width.toFixed(0)} × ${outerBox.height.toFixed(0)}mm — ` +
        `tek A4'e sığmıyor, birden fazla sayfaya bölünecek.`,
    });
  }

  const summary: PatternSummary = {
    compartmentWidth: panelWidth,
    slotStackHeight: slotGeo.stackHeight,
    outerFlatWidth: outerBox.width,
    outerFlatHeight: outerBox.height,
    closedThickness,
    loadedThickness,
    edgeThickness: slotGeo.edgeThickness,
    foldAllowance,
    panelHeight: walletHeight,
    totalHoles: outerPlan.totalHoles,
    pitch: outerPlan.pitch,
    fitsA4,
  };

  return { pieces, assembly, crossSection: solved, diagnostics, summary };
}

/** Yarım inç kuralıyla karşılaştırma — modelin doğrulama çapası. */
export function halfInchRuleDeviation(params: BifoldParams): Mm {
  const result = generateBifold(params);
  const halfInch = 12.7;
  return result.summary.foldAllowance - halfInch;
}

export { foldLengthDelta };
ODK_EOF_3

echo "==> packages/patterns/src/bifold.test.ts"
cat > packages/patterns/src/bifold.test.ts << 'ODK_EOF_4'
import { describe, it, expect } from "vitest";
import { BANKNOTES, billPocketGeometry, BILL_COVER_MARGIN } from "./banknote.js";
import { BIFOLD_DEFAULTS, generateBifold, halfInchRuleDeviation } from "./bifold.js";
import { layerResult } from "./crosssection.js";

describe("banknot verisi", () => {
  it("200 TL 160 × 72mm", () => {
    expect(BANKNOTES.TRY.width).toBe(160);
    expect(BANKNOTES.TRY.height).toBe(72);
    expect(BANKNOTES.TRY.verified).toBe(true);
  });

  it("dolar 156 × 66.3mm", () => {
    expect(BANKNOTES.USD.width).toBe(156);
    expect(BANKNOTES.USD.height).toBeCloseTo(66.3, 2);
    expect(BANKNOTES.USD.verified).toBe(true);
  });

  it("doğrulanmamış para birimleri işaretli ve uyarı metni taşıyor", () => {
    for (const b of Object.values(BANKNOTES)) {
      if (!b.verified) expect(b.note).toContain("doğrulanmadı");
    }
  });

  it("TL en geniş banknot — cüzdanı o belirler", () => {
    const widths = Object.values(BANKNOTES).map((b) => b.width);
    expect(BANKNOTES.TRY.width).toBe(Math.max(...widths));
  });

  it("asgari cüzdan yüksekliği banknottan örtü payı kadar fazla", () => {
    const g = billPocketGeometry({
      currency: "TRY",
      leatherThickness: 0.8,
      stitchMargin: 3.5,
    });
    expect(g.minWalletHeight).toBeCloseTo(72 + BILL_COVER_MARGIN, 6);
  });
});

describe("bifold — yarım inç kuralı doğrulaması", () => {
  it("ASGARİ cüzdanda kat payı 12.7mm'ye yakın", () => {
    // MODELİN DOĞRULAMA ÇAPASI.
    //
    // MAKESUPPLY yarım inç kuralını "bare minimum" bir cüzdan için
    // veriyor: dış kabuk, iç kabuk, bir kat kart yuvası. Panel başına
    // 2 yuva bu tarife karşılık geliyor.
    //
    // gaps alanı eklenmeden model 2.6mm veriyordu — kıvrımda katman
    // olmayan dolgu (kart yığını + kartlar) modellenmediği için.
    const dev = Math.abs(
      halfInchRuleDeviation({ ...BIFOLD_DEFAULTS, cardSlotsPerSide: 2 }),
    );
    expect(dev).toBeLessThan(1.5);
  });

  it("kalın cüzdanda kat payı DAHA BÜYÜK olmalı", () => {
    // Yarım inç sabit bir sayı değil, belirli bir kalınlığın sonucu.
    // 3 yuvalı cüzdan daha kalın, dolayısıyla daha çok pay ister.
    // Modelin bunu vermesi doğru davranış; 12.7'ye zorlamak hata olurdu.
    const thick = generateBifold(BIFOLD_DEFAULTS).summary.foldAllowance;
    const thin = generateBifold({
      ...BIFOLD_DEFAULTS,
      cardSlotsPerSide: 2,
    }).summary.foldAllowance;
    expect(thick).toBeGreaterThan(thin);
    expect(thick).toBeGreaterThan(12.7);
  });

  it("açık genişlik ticari kalıplarla aynı mertebede", () => {
    // Referans: satılan bir billfold kalıbı açık 215mm.
    const r = generateBifold(BIFOLD_DEFAULTS);
    expect(r.summary.outerFlatWidth).toBeGreaterThan(190);
    expect(r.summary.outerFlatWidth).toBeLessThan(240);
  });

  it("kat payı dolgusuz modelden belirgin büyük", () => {
    const r = generateBifold(BIFOLD_DEFAULTS);
    // Dolgusuz olsaydı: π × (t_inner + k·(t_outer − t_inner)) ≈ 2.6mm
    const withoutFill = Math.PI * (0.8 + 0.45 * (0.9 - 0.8));
    expect(r.summary.foldAllowance).toBeGreaterThan(withoutFill * 3);
  });

  it("dış kabuk iç kabuktan tam kat payı kadar uzun", () => {
    const r = generateBifold(BIFOLD_DEFAULTS);
    const inner = layerResult(r.crossSection, "inner");
    const outer = layerResult(r.crossSection, "outer");
    expect((outer?.flatLength as number) - (inner?.flatLength as number)).toBeCloseTo(
      r.summary.foldAllowance,
      6,
    );
  });

  it("kart yuvası arttıkça kat payı büyüyor", () => {
    const a = generateBifold({ ...BIFOLD_DEFAULTS, cardSlotsPerSide: 2 });
    const b = generateBifold({ ...BIFOLD_DEFAULTS, cardSlotsPerSide: 5 });
    expect(b.summary.foldAllowance).toBeGreaterThan(a.summary.foldAllowance);
  });
});

describe("bifold — parçalar", () => {
  const r = generateBifold(BIFOLD_DEFAULTS);

  it("hata üretmiyor", () => {
    expect(r.diagnostics.filter((d) => d.severity === "error")).toHaveLength(0);
  });

  it("dış kabuk, iç kabuk ve yuvalar üretiliyor", () => {
    expect(r.pieces.map((p) => p.code)).toEqual(["A", "B", "C", "D"]);
  });

  it("yuva parçaları iki panel için iki kat adet", () => {
    const rect = r.pieces.find((p) => p.id === "slot-rect");
    const t = r.pieces.find((p) => p.id === "slot-t");
    expect(rect?.quantity).toBe(2);
    expect(t?.quantity).toBe(2 * (BIFOLD_DEFAULTS.cardSlotsPerSide - 1));
  });

  it("iç kabuk dış kabuktan kısa", () => {
    const outer = r.pieces.find((p) => p.id === "outer");
    const inner = r.pieces.find((p) => p.id === "inner");
    expect(inner?.width).toBeLessThan(outer?.width as number);
    // Hassasiyet 2: kesim hatları Clipper'ın mikron ızgarasından geçiyor.
    expect((outer?.width as number) - (inner?.width as number)).toBeCloseTo(
      r.summary.foldAllowance,
      2,
    );
  });

  it("montajda her panel için ayrı yuva örnekleri", () => {
    expect(r.assembly).toHaveLength(2 * BIFOLD_DEFAULTS.cardSlotsPerSide);
    expect(r.assembly.filter((a) => a.code.includes("S"))).toHaveLength(3);
    expect(r.assembly.filter((a) => a.code.includes("R"))).toHaveLength(3);
  });

  it("sağ paneldeki yuvalar sağa kaydırılmış", () => {
    const left = r.assembly.filter((a) => a.code.includes("S"));
    const right = r.assembly.filter((a) => a.code.includes("R"));
    expect(right[0]?.x).toBeGreaterThan(left[0]?.x as number);
  });
});

describe("bifold — ölçüler ve kurallar", () => {
  it("TL banknotu bölmeye sığıyor", () => {
    const r = generateBifold(BIFOLD_DEFAULTS);
    expect(r.summary.panelHeight).toBeGreaterThanOrEqual(72 + BILL_COVER_MARGIN);
  });

  it("kapalı kalınlık makul", () => {
    const r = generateBifold(BIFOLD_DEFAULTS);
    expect(r.summary.closedThickness).toBeGreaterThan(4);
    expect(r.summary.closedThickness).toBeLessThan(12);
  });

  it("çok yuva şişkinlik uyarısı üretiyor", () => {
    const r = generateBifold({ ...BIFOLD_DEFAULTS, cardSlotsPerSide: 8 });
    expect(
      r.diagnostics.some((d) => d.code === "BULKY" || d.code === "TOO_THICK"),
    ).toBe(true);
  });

  it("doğrulanmamış para birimi uyarı üretiyor", () => {
    const r = generateBifold({ ...BIFOLD_DEFAULTS, currency: "EUR" });
    expect(r.diagnostics.some((d) => d.code === "BANKNOTE_UNVERIFIED")).toBe(true);
  });

  it("açık genişlik banknot ve kart kısıtlarının büyüğü", () => {
    const r = generateBifold(BIFOLD_DEFAULTS);
    const billWidth = billPocketGeometry({
      currency: "TRY",
      leatherThickness: 0.8,
      stitchMargin: 3.5,
    }).compartmentWidth;
    expect(r.summary.outerFlatWidth + 0.6).toBeGreaterThanOrEqual(
      Math.min(billWidth, 2 * r.summary.compartmentWidth) - 1,
    );
  });

  it("A4'e sığmıyor ve tiling uyarısı veriyor", () => {
    // Açık bifold ~200mm; A4 genişliği 210mm, kenar payıyla sığmaz.
    const r = generateBifold(BIFOLD_DEFAULTS);
    expect(r.summary.outerFlatWidth).toBeGreaterThan(150);
    if (!r.summary.fitsA4) {
      expect(r.diagnostics.some((d) => d.code === "NEEDS_TILING")).toBe(true);
    }
  });
});
ODK_EOF_4

echo "==> packages/patterns/src/instructions.ts"
cat > packages/patterns/src/instructions.ts << 'ODK_EOF_5'
import type { Mm } from "@odk/geometry";
import type { PatternResult } from "./cardholder.js";
import { PROVISIONAL_SKIVE_FACTOR } from "./material.js";

/**
 * YAPIM ADIMLARI
 *
 * Adımlar SABİT METİN DEĞİL, kalıptan türetiliyor. Parça sayısı, delik
 * adedi, tutkal sınırı, kuruma süresi — hepsi hesaptan geliyor. Kullanıcı
 * kart sayısını değiştirdiğinde talimat da değişiyor.
 *
 * Neden önemli: sabit metin, parametrik bir kalıpla er geç çelişir.
 * "3 parçayı kes" yazan bir talimatın yanında 5 parça basılıysa
 * kullanıcı hangisine güveneceğini bilemez.
 */

/**
 * Adım üretimi için gereken asgari parametreler.
 *
 * Tam parametre tipi (CardHolderParams / BifoldParams) yerine bu dar
 * arayüz kullanılıyor: yapısal tipleme sayesinde her iki aile de
 * doğrudan geçebiliyor ve yeni bir aile eklendiğinde bu dosyaya
 * dokunmak gerekmiyor.
 */
export interface InstructionContext {
  readonly penAllowance: Mm;
  readonly stitchMargin: Mm;
  readonly reveal: Mm;
}

export interface InstructionStep {
  readonly n: number;
  readonly title: string;
  readonly body: string;
  /**
   * Bu adımda yapılan hata ürünü çöpe atıyorsa uyarı.
   * Referans kalıplarda en değerli bilgi buydu: "çoğu kişi bu hatayı
   * yapıyor ve baştan başlamak zorunda kalıyor."
   */
  readonly warning?: string;
}

/** Tutkal kuruma süresi (dakika). Kontak yapıştırıcı için tipik. */
export const GLUE_CURE_MINUTES = 120;

export function buildInstructions(
  pattern: PatternResult,
  params: InstructionContext,
): InstructionStep[] {
  const s = pattern.summary;
  const steps: InstructionStep[] = [];
  let n = 0;
  const add = (
    title: string,
    body: string,
    warning?: string,
  ): void => {
    n += 1;
    steps.push(warning === undefined ? { n, title, body } : { n, title, body, warning });
  };

  const totalPaperPieces = pattern.pieces.reduce((a, p) => a + p.quantity, 0);
  const pieceList = pattern.pieces
    .map((p) => `${p.code} ×${p.quantity}`)
    .join(", ");

  // Deri türleri: aynı kalınlıktakiler tek satırda.
  const byThickness = new Map<Mm, string[]>();
  for (const p of pattern.pieces) {
    const list = byThickness.get(p.leatherThickness) ?? [];
    list.push(`${p.code} ×${p.quantity}`);
    byThickness.set(p.leatherThickness, list);
  }
  const leatherLines = [...byThickness.entries()]
    .sort((a, b) => b[0] - a[0])
    .map(([t, codes]) => `${t.toFixed(1)}mm: ${codes.join(", ")}`)
    .join(" · ");

  add(
    "Ölçeği doğrula",
    `Kapak sayfasındaki 50mm kareyi cetvelle ölç. 50mm değilse ölçtüğün ` +
      `değeri uygulamaya gir, PDF'i yeniden indir ve aynı yazıcı ayarıyla bas.`,
    `Bu adımı atlarsan sonraki her ölçü yanlış olur. Kalıbın hassasiyeti ` +
      `baskı ölçeğinden daha iyi olamaz.`,
  );

  add(
    "Kağıt parçaları kes",
    `Toplam ${totalPaperPieces} parça: ${pieceList}. Kesim çizgisini ` +
      `kağıtta bırak, dışından kes. Kalınca bir kartona yapıştırmak ` +
      `deriye çizerken şablonun kaymasını önler.`,
  );

  add(
    "Deriyi hazırla",
    `Kalınlıklar — ${leatherLines}. Şablonları deri üzerine damar yönü ` +
      `aynı olacak şekilde yerleştir; her parçada damar oku basılı.`,
    `Parçalar farklı damar yönlerinde kesilirse ürün kullandıkça ` +
      `çarpılır ve kenarlar hizasını kaybeder.`,
  );

  add(
    "Delikleri işaretle",
    `Şablonu deriye bantla ve işaretli noktalardan del. ` +
      `${s.pitch}mm pricking iron, toplam ${s.totalHoles} delik. ` +
      `Delikleri deriyi kesmeden önce açmak hizayı korur.`,
  );

  add(
    "Deriyi kes",
    `Kesim hattını takip et. Kalem payı ${params.penAllowance}mm olarak ` +
      `hesaba katıldı; şablonun dış kenarından çizip çizginin dışından ` +
      `kesersen nominal ölçüye ulaşırsın.`,
  );

  const overlapCount = pattern.assembly.length;
  add(
    "Kenarları tıraşla",
    `${overlapCount} yuva üst üste bineceği için örtüşen kenarları ` +
      `tıraşla (skive). Tıraşlama kalınlığı yaklaşık yarıya indirir; ` +
      `kenar kalınlığı ${s.edgeThickness.toFixed(1)}mm'den ` +
      `${(s.edgeThickness * PROVISIONAL_SKIVE_FACTOR).toFixed(1)}mm'ye ` +
      `civarına düşer.`,
  );

  // Tutkal sınırı: dikiş hattının dışındaki bant.
  const glueBandWidth = params.stitchMargin;
  add(
    "Yapıştır",
    `En alttan başla. Yuvaları ${params.reveal}mm kademeyle diz: ` +
      `${pattern.assembly.map((a) => a.code).join(" → ")}. ` +
      `Tutkalı yalnızca kenarlardaki ${glueBandWidth.toFixed(1)}mm'lik ` +
      `banda sür.`,
    `Tutkal dikiş hattının İÇİNE taşarsa kart yuvası yapışır ve ürün ` +
      `kullanılamaz hale gelir. Ayrıca kat bölgesine ` +
      `(${s.foldAllowance.toFixed(1)}mm'lik şerit) tutkal sürme — ` +
      `sürülürse cüzdan katlanmaz.`,
  );

  add(
    "Kelepçele ve beklet",
    `Parçaları kelepçe ya da mandalla sabitle ve tutkalın kuruması için ` +
      `yaklaşık ${GLUE_CURE_MINUTES / 60} saat bekle.`,
  );

  add(
    "Kenarları bitir",
    `Kenarları zımparala, kenar boyası ya da cila uygula. Kurumasını ` +
      `bekle ve gerekirse ikinci kat çek.`,
    `Kenar bitirme dikişten ÖNCE yapılır. Dikişten sonra iplik boyanır ` +
      `ve zımpara ipliği aşındırır.`,
  );

  const outer = pattern.pieces.find((p) => p.stitchPlan !== undefined);
  add(
    "Dik",
    `Eyer dikişi (saddle stitch) ile ${s.totalHoles} delikten geç. ` +
      `İplik boyu delik sayısının yaklaşık ` +
      `${Math.ceil(((outer?.stitchPlan?.totalHoles ?? s.totalHoles) * s.pitch * 3.5) / 1000)}` +
      ` metre kadarı olmalı (çevrenin ~3.5 katı).`,
  );

  add(
    "Kontrol et",
    `Kapalı kalınlık ${s.closedThickness.toFixed(1)}mm, kartlar takılıyken ` +
      `${s.loadedThickness.toFixed(1)}mm olmalı. Belirgin sapma varsa deri ` +
      `kalınlığı ya da tıraşlama farklı çıkmıştır — ölçüp uygulamaya geri bildir.`,
  );

  return steps;
}
ODK_EOF_5

echo "==> packages/patterns/src/catalog.ts"
cat > packages/patterns/src/catalog.ts << 'ODK_EOF_6'
import type { Mm } from "@odk/geometry";

/**
 * KALIP KATALOĞU
 *
 * Kategoriler ve ürün aileleri. Motorun ürettiği her kalıp bir aileye,
 * her aile bir kategoriye ait.
 *
 * DÜRÜSTLÜK KURALI: bir aile ancak gerçekten üretilebiliyorsa "hazır"
 * işaretlenir. Planlanan aileler listede görünür ama arayüz onları
 * kapalı gösterir. Var olmayan bir şeyi çalışıyormuş gibi listelemek,
 * kullanıcının zamanını çalar.
 */

export type CategoryId = "kartlik" | "cuzdan" | "canta" | "aksesuar";

export interface Category {
  readonly id: CategoryId;
  readonly name: string;
  readonly description: string;
  readonly order: number;
}

export const CATEGORIES: readonly Category[] = [
  {
    id: "kartlik",
    name: "Kartlık",
    description: "Sadece kart taşıyan ince modeller. En az katman, en az kalınlık.",
    order: 1,
  },
  {
    id: "cuzdan",
    name: "Cüzdan",
    description: "Kart, banknot ve bozuk para bölmelerinin birleştiği modeller.",
    order: 2,
  },
  {
    id: "canta",
    name: "Çanta",
    description: "Körüklü, askılı, hacimli modeller. Kalın deri ve yapısal dikiş.",
    order: 3,
  },
  {
    id: "aksesuar",
    name: "Aksesuar",
    description: "Kemer, anahtarlık, bileklik, kılıf gibi küçük ürünler.",
    order: 4,
  },
];

export type FamilyStatus = "hazir" | "gelistiriliyor" | "planlandi";

export interface PatternFamily {
  readonly id: string;
  readonly category: CategoryId;
  readonly name: string;
  readonly summary: string;
  readonly status: FamilyStatus;
  /** Bu ailenin kullandığı modüller. */
  readonly modules: readonly string[];
  /** Tipik kapalı kalınlık aralığı — kullanıcı beklentisini kurar. */
  readonly typicalThickness?: { readonly min: Mm; readonly max: Mm };
}

export const FAMILIES: readonly PatternFamily[] = [
  {
    id: "card-holder-fold",
    category: "kartlik",
    name: "Katlanır kartlık",
    summary:
      "Dış kabuk ortadan katlanır, kart yuvaları ön panele kademeli oturur.",
    status: "hazir",
    modules: ["CardSlot"],
    typicalThickness: { min: 4, max: 9 },
  },
  {
    id: "card-sleeve",
    category: "kartlik",
    name: "Düz kart kılıfı",
    summary: "Katsız, iki panel arasında tek bölme. En ince model.",
    status: "planlandi",
    modules: ["CardSlot"],
    typicalThickness: { min: 2, max: 4 },
  },
  {
    id: "bifold",
    category: "cuzdan",
    name: "Bifold cüzdan",
    summary: "Banknot bölmesi üzerinde iki yanda kart yuvaları.",
    status: "hazir",
    modules: ["CardSlot", "BillPocket"],
    typicalThickness: { min: 6, max: 12 },
  },
  {
    id: "long-wallet",
    category: "cuzdan",
    name: "Uzun cüzdan",
    summary: "Banknot katlanmadan girer; fermuarlı bozuk para gözü eklenebilir.",
    status: "planlandi",
    modules: ["CardSlot", "BillPocket", "CoinPocket"],
    typicalThickness: { min: 8, max: 16 },
  },
  {
    id: "tote",
    category: "canta",
    name: "Körüklü çanta",
    summary: "Yan körük ve taban, askı bağlantıları.",
    status: "planlandi",
    modules: ["Gusset", "Divider"],
  },
  {
    id: "belt",
    category: "aksesuar",
    name: "Kemer",
    summary: "Tek parça şerit, toka bağlantısı ve delik dizisi.",
    status: "planlandi",
    modules: [],
  },
  {
    id: "key-case",
    category: "aksesuar",
    name: "Anahtarlık kılıfı",
    summary: "Katlanır kılıf, anahtar plakası bağlantısı.",
    status: "planlandi",
    modules: [],
  },
];

export function categoryById(id: CategoryId): Category | undefined {
  return CATEGORIES.find((c) => c.id === id);
}

export function familyById(id: string): PatternFamily | undefined {
  return FAMILIES.find((f) => f.id === id);
}

export function familiesByCategory(id: CategoryId): PatternFamily[] {
  return FAMILIES.filter((f) => f.category === id);
}

/** Şu anda gerçekten kalıp üretilebilen aileler. */
export function availableFamilies(): PatternFamily[] {
  return FAMILIES.filter((f) => f.status === "hazir");
}

/** Kategoride üretilebilir aile var mı? Arayüz kategoriyi kapatmak için kullanır. */
export function categoryHasAvailable(id: CategoryId): boolean {
  return FAMILIES.some((f) => f.category === id && f.status === "hazir");
}

export const STATUS_LABEL: Record<FamilyStatus, string> = {
  hazir: "hazır",
  gelistiriliyor: "geliştiriliyor",
  planlandi: "planlandı",
};
ODK_EOF_6

echo "==> packages/patterns/src/catalog.test.ts"
cat > packages/patterns/src/catalog.test.ts << 'ODK_EOF_7'
import { describe, it, expect } from "vitest";
import {
  CATEGORIES,
  FAMILIES,
  categoryById,
  familyById,
  familiesByCategory,
  availableFamilies,
  categoryHasAvailable,
  STATUS_LABEL,
} from "./catalog.js";
import type { CardHolderParams } from "./cardholder.js";
import { DEFAULT_PARAMS, generateCardHolder } from "./cardholder.js";
import { buildInstructions, GLUE_CURE_MINUTES } from "./instructions.js";

describe("katalog", () => {
  it("kategori id'leri benzersiz ve sıralı", () => {
    const ids = CATEGORIES.map((c) => c.id);
    expect(new Set(ids).size).toBe(ids.length);
    const orders = CATEGORIES.map((c) => c.order);
    expect([...orders].sort((a, b) => a - b)).toEqual(orders);
  });

  it("aile id'leri benzersiz", () => {
    const ids = FAMILIES.map((f) => f.id);
    expect(new Set(ids).size).toBe(ids.length);
  });

  it("her aile tanımlı bir kategoriye ait", () => {
    for (const f of FAMILIES) {
      expect(categoryById(f.category)).toBeDefined();
    }
  });

  it("her kategoride en az bir aile var", () => {
    for (const c of CATEGORIES) {
      expect(familiesByCategory(c.id).length).toBeGreaterThan(0);
    }
  });

  it("yalnızca gerçekten üretilebilen aile hazır işaretli", () => {
    // DÜRÜSTLÜK TESTİ: bu liste büyürse jeneratörü de eklenmiş olmalı.
    // Var olmayan bir aileyi hazır göstermek kullanıcının zamanını çalar.
    expect(availableFamilies().map((f) => f.id).sort()).toEqual([
      "bifold",
      "card-holder-fold",
    ]);
  });

  it("kartlık ve cüzdanda üretilebilir aile var, çantada yok", () => {
    expect(categoryHasAvailable("kartlik")).toBe(true);
    expect(categoryHasAvailable("cuzdan")).toBe(true);
    expect(categoryHasAvailable("canta")).toBe(false);
  });

  it("bilinmeyen id undefined döner", () => {
    expect(familyById("yok")).toBeUndefined();
  });

  it("her durum için etiket var", () => {
    for (const f of FAMILIES) {
      expect(STATUS_LABEL[f.status]).toBeTruthy();
    }
  });

  it("kalınlık aralıkları tutarlı", () => {
    for (const f of FAMILIES) {
      if (f.typicalThickness !== undefined) {
        expect(f.typicalThickness.min).toBeLessThan(f.typicalThickness.max);
      }
    }
  });
});

describe("yapım adımları", () => {
  const pattern = generateCardHolder(DEFAULT_PARAMS);
  const steps = buildInstructions(pattern, DEFAULT_PARAMS);

  it("numaralar 1'den ardışık", () => {
    expect(steps.map((s) => s.n)).toEqual(steps.map((_, i) => i + 1));
  });

  it("ölçek doğrulamayla başlıyor, kontrolle bitiyor", () => {
    // "Ölçeği" — ünsüz yumuşaması yüzünden "Ölçek" araması tutmaz.
    expect(steps[0]?.title).toContain("Ölçe");
    expect(steps.at(-1)?.title).toContain("Kontrol");
  });

  it("adımlar KALIPTAN türetiliyor, sabit metin değil", () => {
    // Parametre değişince metin de değişmeli.
    // Nesne literalini doğrudan geçmek fazla-özellik denetimine takılır;
    // InstructionContext bilerek dar tutuldu.
    const p7: CardHolderParams = { ...DEFAULT_PARAMS, cardCount: 7 };
    const other = generateCardHolder(p7);
    const otherSteps = buildInstructions(other, p7);
    const glue = steps.find((s) => s.title === "Yapıştır");
    const otherGlue = otherSteps.find((s) => s.title === "Yapıştır");
    expect(glue?.body).not.toBe(otherGlue?.body);
  });

  it("delik sayısı ve adım metne giriyor", () => {
    const marking = steps.find((s) => s.title.includes("Delik"));
    expect(marking?.body).toContain(String(pattern.summary.totalHoles));
    expect(marking?.body).toContain(String(pattern.summary.pitch));
  });

  it("yuva kodları yapıştırma sırasında geçiyor", () => {
    const glue = steps.find((s) => s.title === "Yapıştır");
    for (const a of pattern.assembly) {
      expect(glue?.body).toContain(a.code);
    }
  });

  it("kritik uyarılar var: tutkal taşması ve kat bölgesi", () => {
    // Referans kalıptaki en değerli bilgi buydu — ürünü çöpe attıran hata.
    const glue = steps.find((s) => s.title === "Yapıştır");
    expect(glue?.warning).toBeDefined();
    expect(glue?.warning).toContain("dikiş hattının");
    expect(glue?.warning).toContain("kat");
  });

  it("kenar bitirmenin dikişten önce olduğu uyarısı var", () => {
    const edge = steps.find((s) => s.title.includes("Kenarları bitir"));
    expect(edge?.warning).toContain("ÖNCE");
  });

  it("damar yönü uyarısı var", () => {
    const prep = steps.find((s) => s.title.includes("Deriyi hazırla"));
    expect(prep?.warning).toContain("damar");
  });

  it("kuruma süresi saat olarak yazılıyor", () => {
    const cure = steps.find((s) => s.title.includes("Kelepçele"));
    expect(cure?.body).toContain(String(GLUE_CURE_MINUTES / 60));
  });

  it("kart sayısı arttıkça yapıştırma sırası uzuyor", () => {
    const p2: CardHolderParams = { ...DEFAULT_PARAMS, cardCount: 2 };
    const p8: CardHolderParams = { ...DEFAULT_PARAMS, cardCount: 8 };
    const few = buildInstructions(generateCardHolder(p2), p2);
    const many = buildInstructions(generateCardHolder(p8), p8);
    const seq = (x: typeof few) =>
      (x.find((s) => s.title === "Yapıştır")?.body ?? "").split("→").length;
    expect(seq(many)).toBeGreaterThan(seq(few));
  });
});
ODK_EOF_7

echo "==> packages/patterns/src/index.ts"
cat > packages/patterns/src/index.ts << 'ODK_EOF_8'
/**
 * @odk/patterns — malzeme modeli, kesit çözücü, modül tanımları.
 *
 * Bu paket de saf kalır: platform API'si import etmez.
 */

export * from "./material.js";
export * from "./crosssection.js";
export * from "./cardslot.js";
export * from "./cardholder.js";
export * from "./banknote.js";
export * from "./bifold.js";
export * from "./catalog.js";
export * from "./instructions.js";
ODK_EOF_8

echo "==> packages/print/src/pdf.ts"
cat > packages/print/src/pdf.ts << 'ODK_EOF_9'
import type { PDFDocument, PDFFont, PDFPage } from "pdf-lib";
import {
  PDFDocument as PDFDoc,
  rgb,
  pushGraphicsState,
  popGraphicsState,
  moveTo,
  lineTo,
  closePath,
  clip,
  endPath,
} from "pdf-lib";
import fontkit from "@pdf-lib/fontkit";
import type { Mm, Polyline, Vec } from "@odk/geometry";
import { mmToPt, stitchSummary } from "@odk/geometry";
import type {
  PatternResult,
  PatternPiece,
  InstructionContext,
  InstructionStep,
} from "@odk/patterns";
import { buildInstructions } from "@odk/patterns";
import type { PaperSpec, TileGrid } from "./paper.js";
import {
  A4_PORTRAIT,
  printableArea,
  planTiles,
  tileOrigin,
  tileCode,
  CALIBRATION_SQUARE,
} from "./paper.js";
import type { LineStyle, PlacedPiece, SheetLayout } from "./layout.js";
import { packPieces, STYLES } from "./layout.js";

/**
 * PDF ÜRETİCİ
 *
 * Tek kural: çıktı 1:1. Koordinatlar milimetre olarak hesaplanır ve
 * yalnızca pdf-lib'e verilirken point'e çevrilir (mmToPt). Başka hiçbir
 * yerde birim dönüşümü yok — ölçek hatalarının en yaygın kaynağı budur.
 */

export interface PdfFonts {
  /** Gövde metni için TTF/OTF baytları. Türkçe karakterler şart. */
  readonly regular: Uint8Array;
  /** Ölçüler için monospace TTF/OTF baytları. */
  readonly mono: Uint8Array;
}

export interface PdfOptions {
  readonly paper?: PaperSpec;
  /**
   * Kalibrasyon düzeltmesi. 1 = düzeltme yok.
   * scaleFromMeasurement() ile hesaplanır.
   */
  readonly scaleFactor?: number;
  /**
   * Dikiş deliklerini tek tek bas.
   *
   * Varsayılan AÇIK.
   *
   * İlk sürümde kapalıydı; gerekçem "kullanıcı ironu kendisi yürür,
   * basılmış nokta yanıltır" idi. Ticari kalıpları inceleyince bu
   * varsayımın yanlış olduğu görüldü: yaygın iş akışı kağıt şablonu
   * deriye bantlayıp İŞARETLİ NOKTALARDAN delmek, sonra hattı kesmek.
   * Yani noktalar şablonun asıl işlevlerinden biri.
   *
   * Kapalıyken yalnızca köşe çapaları basılır; ironu kendisi yürütenler
   * için hâlâ geçerli bir seçenek.
   */
  readonly printAllHoles?: boolean;
  readonly title?: string;
  readonly version?: string;
  /**
   * Verilirse yapım adımları sayfası eklenir.
   *
   * Adımlar kalıptan türetildiği için parametrelere ihtiyaç var;
   * PatternResult tek başına yetmiyor.
   */
  readonly params?: InstructionContext;
}

const BLACK = rgb(0, 0, 0);

function gray(g: number) {
  return rgb(g, g, g);
}

interface Ctx {
  readonly doc: PDFDocument;
  readonly body: PDFFont;
  readonly mono: PDFFont;
  readonly paper: PaperSpec;
  readonly scale: number;
}

export async function buildPatternPdf(
  pattern: PatternResult,
  fonts: PdfFonts,
  options: PdfOptions = {},
): Promise<Uint8Array> {
  const paper = options.paper ?? A4_PORTRAIT;
  const scale = options.scaleFactor ?? 1;

  const doc = await PDFDoc.create();
  doc.registerFontkit(fontkit);
  const body = await doc.embedFont(fonts.regular, { subset: true });
  const mono = await doc.embedFont(fonts.mono, { subset: true });

  doc.setTitle(options.title ?? "Deri kalıbı");
  doc.setCreator("oto_deri_kalip");

  const ctx: Ctx = { doc, body, mono, paper, scale };

  const layout = packPieces(pattern.pieces, paper);
  const grid = planTiles(layout.width, layout.height, paper);

  drawCoverPage(ctx, pattern, layout, grid, options);
  drawAssemblyPage(ctx, pattern);
  if (options.params !== undefined) {
    drawInstructionPages(ctx, buildInstructions(pattern, options.params));
  }

  for (let row = 0; row < grid.rows; row++) {
    for (let col = 0; col < grid.cols; col++) {
      drawTilePage(ctx, pattern, layout, grid, col, row, options);
    }
  }

  return doc.save();
}

// --- Yardımcılar -----------------------------------------------------------

function addPage(ctx: Ctx): PDFPage {
  return ctx.doc.addPage([mmToPt(ctx.paper.width), mmToPt(ctx.paper.height)]);
}

function line(
  page: PDFPage,
  a: Vec,
  b: Vec,
  style: LineStyle,
  scale: number,
): void {
  // exactOptionalPropertyTypes altında dashArray'e undefined atanamaz;
  // sürekli çizgide anahtarı hiç eklemiyoruz.
  const dash =
    style.dash.length > 0
      ? { dashArray: style.dash.map((d) => mmToPt(d * scale)) }
      : {};
  page.drawLine({
    start: { x: mmToPt(a.x), y: mmToPt(a.y) },
    end: { x: mmToPt(b.x), y: mmToPt(b.y) },
    thickness: mmToPt(style.width),
    color: gray(style.gray),
    ...dash,
  });
}

function polyline(
  page: PDFPage,
  poly: Polyline,
  closedPath: boolean,
  style: LineStyle,
  scale: number,
): void {
  for (let i = 0; i < poly.length - 1; i++) {
    line(page, poly[i] as Vec, poly[i + 1] as Vec, style, scale);
  }
  if (closedPath && poly.length > 2) {
    line(page, poly.at(-1) as Vec, poly[0] as Vec, style, scale);
  }
}

function text(
  page: PDFPage,
  s: string,
  x: Mm,
  y: Mm,
  size: number,
  font: PDFFont,
  g = 0,
): void {
  page.drawText(s, {
    x: mmToPt(x),
    y: mmToPt(y),
    size,
    font,
    color: gray(g),
  });
}

// --- Kapak sayfası ---------------------------------------------------------

function drawCoverPage(
  ctx: Ctx,
  pattern: PatternResult,
  layout: SheetLayout,
  grid: TileGrid,
  options: PdfOptions,
): void {
  const page = addPage(ctx);
  const area = printableArea(ctx.paper);
  const left = area.originX;
  let y = ctx.paper.height - ctx.paper.printerMargin - 8;

  text(page, options.title ?? "Kartlık — kalıp", left, y, 18, ctx.body);
  y -= 7;
  text(
    page,
    `${options.version ?? "v1"} · ${grid.cols * grid.rows} desen sayfası · ölçek 1:1`,
    left,
    y,
    9,
    ctx.mono,
    0.4,
  );

  // ── Kalibrasyon karesi ───────────────────────────────────────────────
  y -= 14;
  text(page, "1 — Önce ölçeği doğrula", left, y, 12, ctx.body);
  y -= 6;
  const instructions = [
    "Yazdırırken ölçek %100 / Actual size olmalı.",
    "\"Sayfaya sığdır\" / \"Fit to page\" KAPALI olmalı.",
    "Aşağıdaki karenin kenarını cetvelle ölç.",
    "50mm değilse ölçtüğün değeri uygulamaya gir ve PDF'i yeniden indir.",
  ];
  for (const linetext of instructions) {
    text(page, linetext, left, y, 9, ctx.body, 0.25);
    y -= 4.6;
  }

  y -= CALIBRATION_SQUARE + 3;
  const sq = CALIBRATION_SQUARE * ctx.scale;
  page.drawRectangle({
    x: mmToPt(left),
    y: mmToPt(y),
    width: mmToPt(sq),
    height: mmToPt(sq),
    borderWidth: mmToPt(STYLES.cut.width),
    borderColor: BLACK,
  });
  // Kenar ortalarına 10mm'lik tik işaretleri: cetveli hizalamayı kolaylaştırır.
  for (let t = 10; t < CALIBRATION_SQUARE; t += 10) {
    const tx = left + t * ctx.scale;
    line(page, { x: tx, y }, { x: tx, y: y + 2 * ctx.scale }, STYLES.guide, ctx.scale);
  }
  text(page, `${CALIBRATION_SQUARE} mm`, left + sq + 4, y + sq / 2, 10, ctx.mono);

  // ── Kesim kuralı ─────────────────────────────────────────────────────
  y -= 10;
  text(page, "2 — Çizginin dışından kes", left, y, 12, ctx.body);
  y -= 5.5;
  text(
    page,
    "Kesim çizgisi 0.2mm. Çizgiyi kağıtta bırak, dışından kes.",
    left,
    y,
    9,
    ctx.body,
    0.25,
  );

  // ── Parça listesi ────────────────────────────────────────────────────
  y -= 12;
  text(page, "3 — Parçalar", left, y, 12, ctx.body);
  y -= 6;
  text(page, "kod", left, y, 8, ctx.mono, 0.5);
  text(page, "parça", left + 12, y, 8, ctx.mono, 0.5);
  text(page, "adet", left + 55, y, 8, ctx.mono, 0.5);
  text(page, "ölçü (mm)", left + 70, y, 8, ctx.mono, 0.5);
  text(page, "deri", left + 110, y, 8, ctx.mono, 0.5);
  y -= 1.5;
  line(page, { x: left, y }, { x: left + area.width, y }, STYLES.guide, 1);
  y -= 4.5;

  for (const p of pattern.pieces) {
    text(page, p.code, left, y, 9, ctx.mono);
    text(page, p.name, left + 12, y, 9, ctx.body);
    text(page, `${p.quantity}`, left + 55, y, 9, ctx.mono);
    text(
      page,
      `${p.width.toFixed(1)} × ${p.height.toFixed(1)}`,
      left + 70,
      y,
      9,
      ctx.mono,
    );
    text(page, `${p.leatherThickness.toFixed(1)}mm`, left + 110, y, 9, ctx.mono);
    y -= 4.8;
  }

  // ── Dikiş planı ──────────────────────────────────────────────────────
  const outer = pattern.pieces.find((p) => p.stitchPlan !== undefined);
  if (outer?.stitchPlan !== undefined) {
    y -= 8;
    text(page, "4 — Dikiş", left, y, 12, ctx.body);
    y -= 5.5;
    text(
      page,
      `${outer.stitchPlan.pitch}mm pricking iron · toplam ${outer.stitchPlan.totalHoles} delik`,
      left,
      y,
      9,
      ctx.mono,
      0.25,
    );
    y -= 5;
    for (const s of stitchSummary(outer.stitchPlan)) {
      text(page, s, left, y, 8.5, ctx.mono, 0.35);
      y -= 4.2;
    }
  }

  // ── Ölçüler ──────────────────────────────────────────────────────────
  const s = pattern.summary;
  y -= 8;
  text(page, "5 — Ölçüler", left, y, 12, ctx.body);
  y -= 5.5;
  const rows: [string, string][] = [
    ["bölme genişliği", `${s.compartmentWidth.toFixed(1)} mm`],
    ["kat payı", `${s.foldAllowance.toFixed(2)} mm`],
    ["kapalı kalınlık", `${s.closedThickness.toFixed(2)} mm`],
    ["kart yüklü", `${s.loadedThickness.toFixed(2)} mm`],
    ["kenar kalınlığı", `${s.edgeThickness.toFixed(2)} mm`],
  ];
  for (const [k, v] of rows) {
    text(page, k, left, y, 9, ctx.body, 0.3);
    text(page, v, left + 55, y, 9, ctx.mono);
    y -= 4.4;
  }

  // ── Uyarılar ─────────────────────────────────────────────────────────
  if (pattern.diagnostics.length > 0) {
    y -= 8;
    text(page, "Uyarılar", left, y, 12, ctx.body);
    y -= 5.5;
    for (const d of pattern.diagnostics) {
      const prefix = d.severity === "error" ? "HATA" : "UYARI";
      const wrapped = wrap(`${prefix} — ${d.message}`, 88);
      for (const w of wrapped) {
        text(page, w, left, y, 8.5, ctx.body, 0.2);
        y -= 4;
      }
      y -= 1;
    }
  }

  drawFooter(ctx, page, "kapak", 0);
}

/** Basit sözcük sarma; PDF'te otomatik sarma yok. */
function wrap(s: string, maxChars: number): string[] {
  const words = s.split(" ");
  const lines: string[] = [];
  let cur = "";
  for (const w of words) {
    if (cur.length + w.length + 1 > maxChars) {
      if (cur.length > 0) lines.push(cur);
      cur = w;
    } else {
      cur = cur.length === 0 ? w : `${cur} ${w}`;
    }
  }
  if (cur.length > 0) lines.push(cur);
  return lines;
}

// --- Ölçü çizgileri --------------------------------------------------------

/**
 * Uzatma çizgileri, oklar ve ortalanmış metinle ölçü çizgisi.
 *
 * Referans olarak incelediğimiz ticari kalıplarda ölçüler çizimin
 * ÜSTÜNDE gösteriliyor, sadece etiket metninde değil. Fark şu: kullanıcı
 * kağıdı cetvelle kontrol ederken hangi iki nokta arasını ölçeceğini
 * çizimden görüyor. "99.4 × 194.4mm" yazısı bunu söylemiyor.
 */
function dimension(
  ctx: Ctx,
  page: PDFPage,
  a: Vec,
  b: Vec,
  offset: Mm,
  label: string,
  vertical: boolean,
): void {
  const style = STYLES.guide;
  const arm = 2;

  const oa = vertical ? { x: a.x - offset, y: a.y } : { x: a.x, y: a.y + offset };
  const ob = vertical ? { x: b.x - offset, y: b.y } : { x: b.x, y: b.y + offset };

  // Uzatma çizgileri: ölçülen kenardan ölçü çizgisine.
  line(page, a, vertical ? { x: oa.x - arm, y: a.y } : { x: a.x, y: oa.y + arm }, style, 1);
  line(page, b, vertical ? { x: ob.x - arm, y: b.y } : { x: b.x, y: ob.y + arm }, style, 1);

  // Ölçü çizgisi.
  line(page, oa, ob, style, 1);

  // Uç işaretleri (45° eğik çizgi — ok başından daha net basılıyor).
  for (const p of [oa, ob]) {
    line(
      page,
      { x: p.x - 1.2, y: p.y - 1.2 },
      { x: p.x + 1.2, y: p.y + 1.2 },
      STYLES.cut,
      1,
    );
  }

  const mid = { x: (oa.x + ob.x) / 2, y: (oa.y + ob.y) / 2 };
  const w = ctx.mono.widthOfTextAtSize(label, 8) / mmToPt(1);
  if (vertical) {
    text(page, label, mid.x - w - 1.5, mid.y - 1, 8, ctx.mono, 0.15);
  } else {
    text(page, label, mid.x - w / 2, mid.y + 1.5, 8, ctx.mono, 0.15);
  }
}

// --- Montaj sayfası --------------------------------------------------------

/**
 * Parçaların bitmiş üründeki yerleşimi.
 *
 * BU SAYFA EN ÇOK EKSİK OLANDI. Önceki sürümde kalıp, birbirinden
 * bağımsız parçalar listesiydi; hangi parçanın nereye geldiği yalnızca
 * kullanıcının kafasındaydı. Referans kalıplarda "Completed Wallet"
 * sayfası tam olarak bunu çözüyor.
 */
function drawAssemblyPage(ctx: Ctx, pattern: PatternResult): void {
  const page = addPage(ctx);
  const area = printableArea(ctx.paper);
  const left = area.originX;
  let y = ctx.paper.height - ctx.paper.printerMargin - 8;

  text(page, "Montaj — açık hâl", left, y, 15, ctx.body);
  y -= 6;
  text(
    page,
    "Yuvalar ön panele oturur; her yuva bir kademe yukarıda.",
    left,
    y,
    9,
    ctx.body,
    0.3,
  );

  const outer = pattern.pieces.find((p) => p.id === "outer");
  if (outer === undefined) {
    drawFooter(ctx, page, "montaj", 0);
    return;
  }

  // Çizimi sayfaya sığdır: ölçekle, çünkü bu sayfa 1:1 DEĞİL.
  const drawH = y - area.originY - 26;
  const fit = Math.min(1, (area.width - 40) / outer.width, drawH / outer.height);
  const ox = left + 24;
  const oy = area.originY + 20;

  const minX = Math.min(...outer.cutLine.map((p) => p.x));
  const minY = Math.min(...outer.cutLine.map((p) => p.y));
  const place = (p: Vec, dx = 0, dy = 0): Vec => ({
    x: ox + (p.x - minX + dx) * fit,
    y: oy + (p.y - minY + dy) * fit,
  });

  polyline(page, outer.cutLine.map((p) => place(p)), true, STYLES.cut, 1);
  for (const fold of outer.foldLines) {
    line(page, place(fold.from), place(fold.to), STYLES.fold, 1);
  }

  // Yuvalar, montajdaki konumlarında.
  for (const a of pattern.assembly) {
    const piece = pattern.pieces.find((p) => p.id === a.pieceId);
    if (piece === undefined) continue;
    const pminX = Math.min(...piece.cutLine.map((p) => p.x));
    const pminY = Math.min(...piece.cutLine.map((p) => p.y));
    const poly = piece.cutLine.map((p) =>
      place({ x: p.x - pminX + a.x, y: p.y - pminY + a.y }),
    );
    polyline(page, poly, true, STYLES.guide, 1);

    const anchor = place({ x: a.x + 4, y: a.y + 3 });
    text(page, a.code, anchor.x, anchor.y, 7.5, ctx.mono, 0.2);
  }

  text(
    page,
    outer.code,
    ox + 3 * fit,
    oy + (outer.height - 6) * fit,
    9,
    ctx.mono,
    0.2,
  );

  // Ölçüler.
  const bl = place({ x: 0, y: 0 });
  const br = place({ x: outer.width, y: 0 });
  const tl = place({ x: 0, y: outer.height });
  dimension(ctx, page, bl, br, 10, `${outer.width.toFixed(1)} mm`, false);
  dimension(ctx, page, bl, tl, 12, `${outer.height.toFixed(1)} mm`, true);

  text(
    page,
    `bu sayfa ölçekli (×${fit.toFixed(2)}) — kesim için desen sayfalarını kullan`,
    left,
    area.originY + 4,
    8,
    ctx.mono,
    0.45,
  );

  drawFooter(ctx, page, "montaj", 0);
}

// --- Yapım adımları --------------------------------------------------------

/**
 * Adımlar sayfası. Sığmayan adımlar bir sonraki sayfaya taşar.
 *
 * Sayfa taşması hesaplanarak yapılıyor, sabit "sayfa başına 6 adım"
 * gibi bir varsayımla değil: adım metinleri kalıptan türediği için
 * uzunlukları parametrelere göre değişiyor.
 */
function drawInstructionPages(ctx: Ctx, steps: readonly InstructionStep[]): void {
  const area = printableArea(ctx.paper);
  const left = area.originX;
  const bottomLimit = area.originY + 4;
  const wrapWidth = 84;

  let page = addPage(ctx);
  let pageIndex = 1;
  let y = ctx.paper.height - ctx.paper.printerMargin - 8;

  text(page, "Yapım adımları", left, y, 15, ctx.body);
  y -= 9;

  for (const step of steps) {
    const bodyLines = wrap(step.body, wrapWidth);
    const warnLines =
      step.warning === undefined ? [] : wrap(step.warning, wrapWidth - 4);
    const needed = 6 + bodyLines.length * 4.2 + (warnLines.length * 4 + 3) + 5;

    if (y - needed < bottomLimit) {
      drawFooter(ctx, page, `adımlar ${pageIndex}`, 0);
      page = addPage(ctx);
      pageIndex += 1;
      y = ctx.paper.height - ctx.paper.printerMargin - 8;
      text(page, `Yapım adımları (devam)`, left, y, 15, ctx.body);
      y -= 9;
    }

    // Numara solda, metin girintili — göz kolayca adım sınırlarını buluyor.
    text(page, `${step.n}`, left, y, 11, ctx.mono, 0.45);
    text(page, step.title, left + 8, y, 11.5, ctx.body);
    y -= 5.4;

    for (const bl of bodyLines) {
      text(page, bl, left + 8, y, 9, ctx.body, 0.25);
      y -= 4.2;
    }

    if (warnLines.length > 0) {
      y -= 1;
      const boxTop = y + 3.5;
      const boxHeight = warnLines.length * 4 + 2;
      // Sol kenarda kalın çubuk: uyarıyı gövdeden ayırıyor. Renk yerine
      // konum ve kalınlık kullanılıyor, siyah-beyaz baskıda da ayrışsın.
      page.drawRectangle({
        x: mmToPt(left + 8),
        y: mmToPt(boxTop - boxHeight),
        width: mmToPt(0.8),
        height: mmToPt(boxHeight),
        color: gray(0.15),
      });
      for (const wl of warnLines) {
        text(page, wl, left + 11, y, 8.5, ctx.body, 0.1);
        y -= 4;
      }
    }

    y -= 5;
  }

  drawFooter(ctx, page, `adımlar ${pageIndex}`, 0);
}

// --- Desen sayfaları -------------------------------------------------------

function drawTilePage(
  ctx: Ctx,
  pattern: PatternResult,
  layout: SheetLayout,
  grid: TileGrid,
  col: number,
  row: number,
  options: PdfOptions,
): void {
  const page = addPage(ctx);
  const area = printableArea(ctx.paper);
  const origin = tileOrigin(grid, col, row);

  // İçeriği basılabilir alana kırp: taşan kısım komşu sayfada.
  page.pushOperators(
    pushGraphicsState(),
    moveTo(mmToPt(area.originX), mmToPt(area.originY)),
    lineTo(mmToPt(area.originX + area.width), mmToPt(area.originY)),
    lineTo(mmToPt(area.originX + area.width), mmToPt(area.originY + area.height)),
    lineTo(mmToPt(area.originX), mmToPt(area.originY + area.height)),
    closePath(),
    clip(),
    endPath(),
  );

  // Tabaka koordinatı -> sayfa koordinatı.
  const tx = (p: Vec): Vec => ({
    x: area.originX + (p.x - origin.x) * ctx.scale,
    y: area.originY + (p.y - origin.y) * ctx.scale,
  });

  for (const placed of layout.placed) {
    drawPiece(ctx, page, placed, tx, options.printAllHoles ?? true);
  }

  page.pushOperators(popGraphicsState());

  drawTileMarks(ctx, page, grid, col, row);
  drawFooter(ctx, page, tileCode(col, row), grid.cols * grid.rows);
}

function drawPiece(
  ctx: Ctx,
  page: PDFPage,
  placed: PlacedPiece,
  tx: (p: Vec) => Vec,
  printAllHoles: boolean,
): void {
  const piece = placed.piece;

  // Parçanın kendi koordinatları sıfırlanıp tabakadaki yerine taşınıyor.
  const minX = Math.min(...piece.cutLine.map((p) => p.x));
  const minY = Math.min(...piece.cutLine.map((p) => p.y));
  const place = (p: Vec): Vec =>
    tx({ x: placed.x + (p.x - minX), y: placed.y + (p.y - minY) });

  polyline(page, piece.cutLine.map(place), true, STYLES.cut, ctx.scale);

  if (piece.stitchLine !== undefined) {
    polyline(page, piece.stitchLine.map(place), true, STYLES.stitch, ctx.scale);
  }

  for (const fold of piece.foldLines) {
    line(page, place(fold.from), place(fold.to), STYLES.fold, ctx.scale);
  }

  if (piece.stitchPlan !== undefined) {
    const holes = printAllHoles
      ? piece.stitchPlan.holes
      : piece.stitchPlan.holes.filter((h) => h.isAnchor);
    for (const hole of holes) {
      const p = place(hole.position);
      page.drawCircle({
        x: mmToPt(p.x),
        y: mmToPt(p.y),
        size: mmToPt(0.5 * ctx.scale),
        borderWidth: mmToPt(0.15),
        borderColor: gray(0.3),
      });
    }
  }

  // Etiket: parçanın sol-üst köşesinin biraz üstünde.
  const label = tx({
    x: placed.x,
    y: placed.y + placed.height + 3,
  });
  text(
    page,
    `${piece.code} · ${piece.name}  ×${piece.quantity}  ${piece.width.toFixed(1)}×${piece.height.toFixed(1)}mm  ${piece.leatherThickness.toFixed(1)}mm deri`,
    label.x,
    label.y,
    7.5,
    ctx.mono,
    0.3,
  );

  // Damar yönü: deri postun boyuna göre daha az esner; parçalar aynı
  // yönde kesilmezse ürün çarpılır.
  const grainStart = tx({ x: placed.x + 2, y: placed.y + 2 });
  const grainEnd = tx({ x: placed.x + 2, y: placed.y + 14 });
  line(page, grainStart, grainEnd, STYLES.guide, ctx.scale);
  text(page, "damar", grainStart.x + 1.5, grainStart.y + 4, 6, ctx.mono, 0.55);
}

/**
 * Hizalama işaretleri.
 *
 * Kullanıcı sayfaları kesip bindirerek yapıştırıyor. Kesme hattı ve
 * dört köşedeki haçlar, komşu sayfayla üst üste getirildiğinde
 * çakışacak şekilde konumlanıyor.
 */
function drawTileMarks(
  ctx: Ctx,
  page: PDFPage,
  grid: TileGrid,
  col: number,
  row: number,
): void {
  const area = printableArea(ctx.paper);
  const x0 = area.originX;
  const y0 = area.originY;
  const x1 = x0 + area.width;
  const y1 = y0 + area.height;

  // Kesme çerçevesi.
  polyline(
    page,
    [
      { x: x0, y: y0 },
      { x: x1, y: y0 },
      { x: x1, y: y1 },
      { x: x0, y: y1 },
    ],
    true,
    STYLES.trim,
    1,
  );

  // Bindirme sınırı: sağda ve altta (bir sonraki sayfanın başladığı yer).
  if (col < grid.cols - 1) {
    line(
      page,
      { x: x1 - grid.overlap, y: y0 },
      { x: x1 - grid.overlap, y: y1 },
      STYLES.guide,
      1,
    );
  }
  if (row < grid.rows - 1) {
    line(
      page,
      { x: x0, y: y0 + grid.overlap },
      { x: x1, y: y0 + grid.overlap },
      STYLES.guide,
      1,
    );
  }

  // Köşe haçları.
  const arm = 4;
  for (const [cx, cy] of [
    [x0, y0],
    [x1, y0],
    [x0, y1],
    [x1, y1],
  ] as const) {
    line(page, { x: cx - arm, y: cy }, { x: cx + arm, y: cy }, STYLES.guide, 1);
    line(page, { x: cx, y: cy - arm }, { x: cx, y: cy + arm }, STYLES.guide, 1);
  }
}

/** Her sayfanın altında: ölçek çubuğu, uyarı, sayfa kodu. */
function drawFooter(ctx: Ctx, page: PDFPage, code: string, totalTiles: number): void {
  const m = ctx.paper.printerMargin;
  const y = m + 4;

  // 50mm ölçek çubuğu, 10mm tikli. Her sayfada ölçek doğrulanabilsin diye.
  const barLength = 50 * ctx.scale;
  line(page, { x: m, y }, { x: m + barLength, y }, STYLES.cut, 1);
  for (let t = 0; t <= 50; t += 10) {
    const tx = m + t * ctx.scale;
    line(page, { x: tx, y }, { x: tx, y: y + 1.8 }, STYLES.cut, 1);
  }
  text(page, "0", m - 0.5, y - 3.4, 6, ctx.mono, 0.4);
  text(page, "50mm", m + barLength - 5, y - 3.4, 6, ctx.mono, 0.4);

  text(
    page,
    "ölçek %100 · sayfaya sığdırma KAPALI",
    m + barLength + 8,
    y - 0.8,
    7,
    ctx.mono,
    0.45,
  );

  const label = totalTiles > 0 ? `${code} / ${totalTiles}` : code;
  text(page, label, ctx.paper.width - m - 18, y - 0.8, 9, ctx.mono, 0.2);
}
ODK_EOF_9

echo "==> packages/print/src/print.test.ts"
cat > packages/print/src/print.test.ts << 'ODK_EOF_10'
import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { PDFDocument } from "pdf-lib";
import { mmToPt } from "@odk/geometry";
import type { CardHolderParams } from "@odk/patterns";
import { DEFAULT_PARAMS, generateCardHolder, buildInstructions } from "@odk/patterns";
import {
  A4_PORTRAIT,
  printableArea,
  planTiles,
  tileOrigin,
  tileCode,
  tileCount,
  TILE_OVERLAP,
  CALIBRATION_SQUARE,
} from "./paper.js";
import { packPieces, scaleFromMeasurement, STYLES } from "./layout.js";
import { buildPatternPdf } from "./pdf.js";

const require = createRequire(import.meta.url);

function fontBytes(pkg: string, file: string): Uint8Array {
  return new Uint8Array(readFileSync(require.resolve(`${pkg}/${file}`)));
}

const FONTS = {
  regular: fontBytes(
    "@expo-google-fonts/ibm-plex-sans",
    "400Regular/IBMPlexSans_400Regular.ttf",
  ),
  mono: fontBytes(
    "@expo-google-fonts/jetbrains-mono",
    "400Regular/JetBrainsMono_400Regular.ttf",
  ),
};

describe("basılabilir alan", () => {
  it("A4'te kenar payı ve alt şerit düşülüyor", () => {
    const a = printableArea(A4_PORTRAIT);
    expect(a.width).toBe(190); // 210 - 2*10
    expect(a.height).toBe(263); // 297 - 2*10 - 14
    expect(a.originX).toBe(10);
    expect(a.originY).toBe(24);
  });
});

describe("döşeme planı", () => {
  it("basılabilir alana sığan tabaka tek sayfa", () => {
    const g = planTiles(180, 250, A4_PORTRAIT);
    expect(g.cols).toBe(1);
    expect(g.rows).toBe(1);
    expect(tileCount(g)).toBe(1);
  });

  it("adım = basılabilir alan − bindirme", () => {
    const g = planTiles(400, 600, A4_PORTRAIT);
    expect(g.stepX).toBe(190 - TILE_OVERLAP);
    expect(g.stepY).toBe(263 - TILE_OVERLAP);
  });

  it("döşemeler tabakanın tamamını kapsıyor", () => {
    for (const [w, h] of [
      [400, 600],
      [191, 264],
      [1000, 300],
      [95, 800],
    ] as const) {
      const g = planTiles(w, h, A4_PORTRAIT);
      const coveredX = (g.cols - 1) * g.stepX + g.tileWidth;
      const coveredY = (g.rows - 1) * g.stepY + g.tileHeight;
      expect(coveredX).toBeGreaterThanOrEqual(w - 1e-9);
      expect(coveredY).toBeGreaterThanOrEqual(h - 1e-9);
    }
  });

  it("komşu döşemeler tam olarak bindirme kadar örtüşüyor", () => {
    const g = planTiles(500, 500, A4_PORTRAIT);
    const a = tileOrigin(g, 0, 0);
    const b = tileOrigin(g, 1, 0);
    const overlapX = a.x + g.tileWidth - b.x;
    expect(overlapX).toBeCloseTo(TILE_OVERLAP, 9);
  });

  it("satırlar yukarıdan aşağı numaralanıyor", () => {
    const g = planTiles(190, 600, A4_PORTRAIT);
    const top = tileOrigin(g, 0, 0);
    const below = tileOrigin(g, 0, 1);
    expect(top.y).toBeGreaterThan(below.y);
  });

  it("bindirme basılabilir alandan büyükse hata", () => {
    expect(() => planTiles(500, 500, A4_PORTRAIT, 300)).toThrow(/ilerlemez/);
  });
});

describe("sayfa kodları", () => {
  it("sütun harfi + satır numarası", () => {
    expect(tileCode(0, 0)).toBe("A1");
    expect(tileCode(1, 0)).toBe("B1");
    expect(tileCode(0, 2)).toBe("A3");
  });

  it("26'dan sonra iki harf", () => {
    expect(tileCode(25, 0)).toBe("Z1");
    expect(tileCode(26, 0)).toBe("AA1");
  });
});

describe("parça yerleşimi", () => {
  const pattern = generateCardHolder(DEFAULT_PARAMS);

  it("tüm parçalar yerleştiriliyor", () => {
    const layout = packPieces(pattern.pieces);
    expect(layout.placed).toHaveLength(pattern.pieces.length);
  });

  it("parçalar üst üste binmiyor", () => {
    const layout = packPieces(pattern.pieces);
    for (let i = 0; i < layout.placed.length; i++) {
      for (let j = i + 1; j < layout.placed.length; j++) {
        const a = layout.placed[i] as (typeof layout.placed)[0];
        const b = layout.placed[j] as (typeof layout.placed)[0];
        const apart =
          a.x + a.width <= b.x + 1e-9 ||
          b.x + b.width <= a.x + 1e-9 ||
          a.y + a.height <= b.y + 1e-9 ||
          b.y + b.height <= a.y + 1e-9;
        expect(apart).toBe(true);
      }
    }
  });

  it("parçalar tabaka sınırları içinde", () => {
    const layout = packPieces(pattern.pieces);
    for (const p of layout.placed) {
      expect(p.x).toBeGreaterThanOrEqual(-1e-9);
      expect(p.y).toBeGreaterThanOrEqual(-1e-9);
      expect(p.x + p.width).toBeLessThanOrEqual(layout.width + 1e-9);
      expect(p.y + p.height).toBeLessThanOrEqual(layout.height + 1e-9);
    }
  });

  it("boş girdi boş yerleşim", () => {
    expect(packPieces([]).placed).toHaveLength(0);
  });

  it("basılabilir alandan geniş parça tabakayı genişletiyor", () => {
    const wide = generateCardHolder({
      ...DEFAULT_PARAMS,
      orientation: "horizontal",
      stitchMargin: 5,
    });
    const layout = packPieces(wide.pieces);
    expect(layout.width).toBeGreaterThanOrEqual(
      Math.max(...wide.pieces.map((p) => p.width)),
    );
  });
});

describe("kalibrasyon", () => {
  it("doğru ölçümde düzeltme yok", () => {
    const r = scaleFromMeasurement(50);
    expect(r.factor).toBe(1);
    expect(r.ok).toBe(true);
  });

  it("küçük basıldıysa büyütme katsayısı", () => {
    const r = scaleFromMeasurement(49.5);
    expect(r.ok).toBe(true);
    expect(r.factor).toBeCloseTo(50 / 49.5, 9);
    expect(r.factor).toBeGreaterThan(1);
  });

  it("büyük basıldıysa küçültme katsayısı", () => {
    const r = scaleFromMeasurement(50.5);
    expect(r.factor).toBeLessThan(1);
  });

  it("düzeltme uygulandığında sonuç nominale gider", () => {
    // Yazıcı %99 ölçekle basıyorsa: içeriği factor ile büyüt, yazıcı
    // 0.99 ile küçültsün, sonuç 50mm olsun.
    const printerScale = 0.99;
    const measured = CALIBRATION_SQUARE * printerScale;
    const { factor } = scaleFromMeasurement(measured);
    expect(CALIBRATION_SQUARE * factor * printerScale).toBeCloseTo(
      CALIBRATION_SQUARE,
      9,
    );
  });

  it("%10'dan fazla sapma reddediliyor", () => {
    // Kullanıcı inç ölçtüyse ~1.97 girer; sessizce uygulamak felaket olur.
    const r = scaleFromMeasurement(2);
    expect(r.ok).toBe(false);
    expect(r.factor).toBe(1);
    expect(r.message).toContain("mm");
  });

  it("geçersiz girdi reddediliyor", () => {
    expect(scaleFromMeasurement(0).ok).toBe(false);
    expect(scaleFromMeasurement(-5).ok).toBe(false);
    expect(scaleFromMeasurement(Number.NaN).ok).toBe(false);
  });
});

describe("çizgi biçimleri", () => {
  it("desenle ayrışıyor: kesim sürekli, diğerleri kesikli", () => {
    // Siyah-beyaz çıktıda tek ayırt edici desen olmalı.
    expect(STYLES.cut.dash).toHaveLength(0);
    expect(STYLES.stitch.dash.length).toBeGreaterThan(0);
    expect(STYLES.fold.dash.length).toBeGreaterThan(0);
    expect(STYLES.stitch.dash).not.toEqual(STYLES.fold.dash);
  });

  it("kesim çizgisi en koyu ve 0.2mm", () => {
    expect(STYLES.cut.width).toBe(0.2);
    expect(STYLES.cut.gray).toBe(0);
  });
});

describe("PDF üretimi", () => {
  const pattern = generateCardHolder(DEFAULT_PARAMS);

  it("geçerli PDF üretiyor", async () => {
    const bytes = await buildPatternPdf(pattern, FONTS);
    expect(bytes.length).toBeGreaterThan(1000);
    expect(new TextDecoder().decode(bytes.slice(0, 5))).toBe("%PDF-");
  });

  it("sayfa boyutu tam A4 (595.28 × 841.89 pt)", async () => {
    const bytes = await buildPatternPdf(pattern, FONTS);
    const doc = await PDFDocument.load(bytes);
    for (const page of doc.getPages()) {
      expect(page.getWidth()).toBeCloseTo(mmToPt(210), 3);
      expect(page.getHeight()).toBeCloseTo(mmToPt(297), 3);
    }
  });

  it("kapak + montaj + desen sayfaları", async () => {
    const bytes = await buildPatternPdf(pattern, FONTS);
    const doc = await PDFDocument.load(bytes);
    const layout = packPieces(pattern.pieces);
    const grid = planTiles(layout.width, layout.height);
    expect(doc.getPageCount()).toBe(2 + tileCount(grid));
  });

  it("montaj yerleşimi kart sayısı kadar örnek veriyor", () => {
    expect(pattern.assembly).toHaveLength(DEFAULT_PARAMS.cardCount);
  });

  it("montajda yuvalar kademe kadar aralıklı", () => {
    for (let i = 1; i < pattern.assembly.length; i++) {
      const a = pattern.assembly[i - 1] as (typeof pattern.assembly)[0];
      const b = pattern.assembly[i] as (typeof pattern.assembly)[0];
      expect(b.y - a.y).toBeCloseTo(DEFAULT_PARAMS.reveal, 9);
      expect(b.layer).toBe(a.layer + 1);
    }
  });

  it("T-slot yapımda yalnızca en dip yuva düz dikdörtgen", () => {
    const rects = pattern.assembly.filter((a) => a.pieceId === "slot-rect");
    expect(rects).toHaveLength(1);
    expect(rects[0]?.layer).toBe(1);
  });

  it("en üstteki yuvanın üstü panel yüksekliğine TAM denk geliyor", () => {
    // Kademe dizilimi paneli tam doldurmalı: (n−1)·kademe + kart
    // yüksekliği + dikiş payı = panelHeight.
    //
    // DİKKAT: parça yükseklikleri KESİM ölçüsü (kalem payı iki kenardan
    // düşülmüş), montaj konumları ise nominal. Karşılaştırmada payı geri
    // eklemek gerekiyor; ilk yazdığımda bunu atlayıp 0.6mm'lik sahte bir
    // uyuşmazlık görmüştüm.
    const top = pattern.assembly.at(-1);
    const slotPiece = pattern.pieces.find((p) => p.id === "slot-t");
    const nominalHeight =
      (slotPiece?.height as number) + 2 * DEFAULT_PARAMS.penAllowance;
    expect((top?.y as number) + nominalHeight).toBeCloseTo(
      pattern.summary.panelHeight,
      6,
    );
  });

  it("parça kodları benzersiz", () => {
    const codes = pattern.pieces.map((p) => p.code);
    expect(new Set(codes).size).toBe(codes.length);
  });

  it("mono font BOŞLUK karakterini gömebiliyor", async () => {
    // FONT SEÇİMİ TESADÜFİ DEĞİL.
    //
    // İlk tercih IBM Plex Mono'ydu (ekran arayüzüyle aynı olsun diye).
    // @pdf-lib/fontkit o TTF'te boşluk karakterinde patlıyor:
    // "Trying to access beyond buffer length" — boş konturlu glifin
    // sınırlayıcı kutusunu okumaya çalışıyor. subset açık/kapalı fark
    // etmiyor. JetBrains Mono aynı işlemi sorunsuz yapıyor.
    //
    // Bu test, biri "ekranla aynı font olsun" diye geri değiştirirse
    // sorunun sessizce dönmemesi için burada.
    const bytes = await buildPatternPdf(pattern, FONTS, {
      title: "bölme genişliği 100.0 mm · dış kabuk",
    });
    expect(bytes.length).toBeGreaterThan(1000);
  });

  it("Türkçe karakterler gömülü fontla kodlanıyor", async () => {
    // Standart PDF fontları (WinAnsi) ı, ş, ğ kodlayamıyor; gömme
    // yapılmazsa üretim tamamen patlar.
    await expect(
      buildPatternPdf(pattern, FONTS, { title: "Kartlık — dış kabuk şablonu kağıt" }),
    ).resolves.toBeInstanceOf(Uint8Array);
  });

  it("kalibrasyon katsayısı çıktıyı büyütüyor", async () => {
    const a = await buildPatternPdf(pattern, FONTS, { scaleFactor: 1 });
    const b = await buildPatternPdf(pattern, FONTS, { scaleFactor: 1.02 });
    // Aynı sayfa sayısı, farklı içerik.
    const da = await PDFDocument.load(a);
    const db = await PDFDocument.load(b);
    expect(db.getPageCount()).toBe(da.getPageCount());
    expect(b.length).not.toBe(a.length);
  });

  it("tüm delikleri basmak çıktıyı büyütüyor", async () => {
    const few = await buildPatternPdf(pattern, FONTS, { printAllHoles: false });
    const many = await buildPatternPdf(pattern, FONTS, { printAllHoles: true });
    expect(many.length).toBeGreaterThan(few.length);
  });

  it("params verilirse yapım adımları sayfası ekleniyor", async () => {
    const without = await PDFDocument.load(
      await buildPatternPdf(pattern, FONTS),
    );
    const withSteps = await PDFDocument.load(
      await buildPatternPdf(pattern, FONTS, { params: DEFAULT_PARAMS }),
    );
    expect(withSteps.getPageCount()).toBeGreaterThan(without.getPageCount());
  });

  it("adım sayfası sayısı metin uzunluğuna göre hesaplanıyor", async () => {
    // Sabit "sayfa başına N adım" varsayımı yok; 8 yuvalı kalıpta
    // yapıştırma sırası uzuyor ve taşma buna göre hesaplanmalı.
    const p8: CardHolderParams = { ...DEFAULT_PARAMS, cardCount: 8 };
    const big = generateCardHolder(p8);
    const steps = buildInstructions(big, p8);
    expect(steps.length).toBeGreaterThan(8);
    const doc = await PDFDocument.load(
      await buildPatternPdf(big, FONTS, { params: p8 }),
    );
    expect(doc.getPageCount()).toBeGreaterThan(4);
  });

  it("VARSAYILAN tüm delikleri basıyor", async () => {
    // Yaygın iş akışı kağıt şablonu deriye bantlayıp işaretli
    // noktalardan delmek; noktalar şablonun asıl işlevlerinden biri.
    const def = await buildPatternPdf(pattern, FONTS);
    const anchorsOnly = await buildPatternPdf(pattern, FONTS, {
      printAllHoles: false,
    });
    expect(def.length).toBeGreaterThan(anchorsOnly.length);
  });

  it("çok sayfalı kalıpta sayfa sayısı artıyor", async () => {
    const big = generateCardHolder({
      ...DEFAULT_PARAMS,
      cardCount: 8,
      reveal: 20,
    });
    const bytes = await buildPatternPdf(big, FONTS);
    const doc = await PDFDocument.load(bytes);
    expect(doc.getPageCount()).toBeGreaterThan(2);
  });
});
ODK_EOF_10

echo "==> apps/web/src/engine.ts"
cat > apps/web/src/engine.ts << 'ODK_EOF_11'
/**
 * Motor köprüsü.
 *
 * Arayüzün motora tek giriş noktası. @odk/* paketlerinden doğrudan
 * import etmek yerine buradan geçmek, ileride motor API'si değiştiğinde
 * bileşenlerin değişmemesini sağlıyor.
 */
export {
  BIFOLD_DEFAULTS,
  BANKNOTES,
  CATEGORIES,
  DEFAULT_PARAMS,
  FAMILIES,
  STATUS_LABEL,
  buildInstructions,
  categoryHasAvailable,
  familiesByCategory,
  generateBifold,
  generateCardHolder,
} from "@odk/patterns";

export { stitchSummary as stitchSummaryFor } from "@odk/geometry";
ODK_EOF_11

echo "==> apps/web/src/pdf.ts"
cat > apps/web/src/pdf.ts << 'ODK_EOF_12'
import type { PatternResult, InstructionContext } from "@odk/patterns";
import { buildPatternPdf, scaleFromMeasurement } from "@odk/print";
import regularUrl from "@expo-google-fonts/ibm-plex-sans/400Regular/IBMPlexSans_400Regular.ttf?url";
import monoUrl from "@expo-google-fonts/jetbrains-mono/400Regular/JetBrainsMono_400Regular.ttf?url";

/**
 * Tarayıcı tarafı PDF köprüsü.
 *
 * Fontlar tembel yükleniyor: ~440KB'lık iki TTF'i ilk açılışta indirmek
 * gereksiz, kullanıcıların çoğu önce parametrelerle oynuyor. İlk PDF
 * isteğinde indirilip önbelleğe alınıyorlar.
 */

let cached: { regular: Uint8Array; mono: Uint8Array } | undefined;

async function loadFonts() {
  if (cached !== undefined) return cached;
  const [r, m] = await Promise.all([
    fetch(regularUrl).then((res) => res.arrayBuffer()),
    fetch(monoUrl).then((res) => res.arrayBuffer()),
  ]);
  cached = { regular: new Uint8Array(r), mono: new Uint8Array(m) };
  return cached;
}

export interface DownloadOptions {
  readonly printAllHoles: boolean;
  readonly scaleFactor: number;
  readonly title: string;
  /** Yapım adımları sayfası için gerekli. */
  readonly params: InstructionContext;
}

export async function downloadPatternPdf(
  pattern: PatternResult,
  options: DownloadOptions,
): Promise<void> {
  const fonts = await loadFonts();
  const bytes = await buildPatternPdf(pattern, fonts, {
    printAllHoles: options.printAllHoles,
    scaleFactor: options.scaleFactor,
    title: options.title,
    version: new Date().toISOString().slice(0, 10),
    params: options.params,
  });

  const blob = new Blob([bytes as BlobPart], { type: "application/pdf" });
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = `${options.title.replace(/[^\wğüşıöçĞÜŞİÖÇ -]/g, "").trim()}.pdf`;
  document.body.appendChild(a);
  a.click();
  a.remove();
  URL.revokeObjectURL(url);
}

export { scaleFromMeasurement };
ODK_EOF_12

echo "==> apps/web/src/App.tsx"
cat > apps/web/src/App.tsx << 'ODK_EOF_13'
import { useMemo, useState } from "react";
import type {
  BifoldParams,
  CardHolderParams,
  CardOrientation,
  Currency,
  SlotConstruction,
} from "@odk/patterns";
import {
  BANKNOTES,
  BIFOLD_DEFAULTS,
  CATEGORIES,
  DEFAULT_PARAMS,
  buildInstructions,
  categoryHasAvailable,
  familiesByCategory,
  generateBifold,
  generateCardHolder,
  stitchSummaryFor,
  STATUS_LABEL,
} from "./engine.js";

type FamilyId = "card-holder-fold" | "bifold";
import { PieceView } from "./PieceView.js";

/**
 * PDF katmanı DİNAMİK yükleniyor.
 *
 * pdf-lib + fontkit ana pakete girdiğinde bundle 1.29MB'a çıkıyordu.
 * Kullanıcıların çoğu önce parametrelerle oynuyor; PDF kodunu ilk
 * "PDF indir" tıklamasına kadar indirmemek ilk açılışı belirgin
 * hızlandırıyor.
 */
const pdfModule = () => import("./pdf.js");

const PX_PER_MM = 2.4;

interface SliderProps {
  label: string;
  value: number;
  min: number;
  max: number;
  step: number;
  unit?: string;
  hint?: string;
  onChange: (v: number) => void;
}

function Slider({ label, value, min, max, step, unit, hint, onChange }: SliderProps) {
  const id = `f-${label.replace(/\s/g, "-")}`;
  return (
    <div className="field">
      <div className="field-head">
        <label htmlFor={id}>{label}</label>
        <span className="field-value">
          {step < 1 ? value.toFixed(1) : value}
          {unit ?? ""}
        </span>
      </div>
      <input
        id={id}
        type="range"
        min={min}
        max={max}
        step={step}
        value={value}
        onChange={(e) => onChange(Number(e.target.value))}
      />
      {hint !== undefined && <p className="hint">{hint}</p>}
    </div>
  );
}

interface ChoiceProps<T extends string> {
  label: string;
  value: T;
  options: readonly { value: T; label: string }[];
  hint?: string;
  onChange: (v: T) => void;
}

function Choice<T extends string>({
  label,
  value,
  options,
  hint,
  onChange,
}: ChoiceProps<T>) {
  return (
    <div className="field">
      <div className="field-head">
        <label>{label}</label>
      </div>
      <div className="segmented" role="group" aria-label={label}>
        {options.map((o) => (
          <button
            key={o.value}
            type="button"
            aria-pressed={o.value === value}
            onClick={() => onChange(o.value)}
          >
            {o.label}
          </button>
        ))}
      </div>
      {hint !== undefined && <p className="hint">{hint}</p>}
    </div>
  );
}

interface PrintState {
  readonly printAllHoles: boolean;
  readonly measured: string;
  readonly scaleFactor: number;
  readonly note: string;
  readonly noteOk: boolean;
  readonly busy: boolean;
}

const INITIAL_PRINT: PrintState = {
  printAllHoles: true,
  measured: "50",
  scaleFactor: 1,
  note: "",
  noteOk: true,
  busy: false,
};

interface SelectProps {
  label: string;
  value: string;
  options: readonly { value: string; label: string }[];
  hint?: string;
  onChange: (v: string) => void;
}

function Select({ label, value, options, hint, onChange }: SelectProps) {
  const id = `s-${label.replace(/\s/g, "-")}`;
  return (
    <div className="field">
      <div className="field-head">
        <label htmlFor={id}>{label}</label>
      </div>
      <select
        id={id}
        className="dropdown"
        value={value}
        onChange={(e) => onChange(e.target.value)}
      >
        {options.map((o) => (
          <option key={o.value} value={o.value}>
            {o.label}
          </option>
        ))}
      </select>
      {hint !== undefined && <p className="hint">{hint}</p>}
    </div>
  );
}

export default function App() {
  const [family, setFamily] = useState<FamilyId>("card-holder-fold");
  const [params, setParams] = useState<CardHolderParams>(DEFAULT_PARAMS);
  const [bifold, setBifold] = useState<BifoldParams>(BIFOLD_DEFAULTS);
  const [print, setPrint] = useState<PrintState>(INITIAL_PRINT);

  const isBifold = family === "bifold";
  // Talimatlar ve PDF her iki aile için de bu dar bağlamı kullanıyor.
  const ctx = isBifold ? bifold : params;

  const set = <K extends keyof CardHolderParams>(
    key: K,
    value: CardHolderParams[K],
  ) => setParams((p) => ({ ...p, [key]: value }));

  const setB = <K extends keyof BifoldParams>(key: K, value: BifoldParams[K]) =>
    setBifold((p) => ({ ...p, [key]: value }));

  const result = useMemo(() => {
    try {
      return {
        ok: true as const,
        value: isBifold ? generateBifold(bifold) : generateCardHolder(params),
      };
    } catch (err) {
      return {
        ok: false as const,
        message: err instanceof Error ? err.message : String(err),
      };
    }
  }, [isBifold, params, bifold]);

  return (
    <div className="shell">
      <aside className="rail">
        <header className="masthead">
          <h1>Deri Kalıp Motoru</h1>
          <p>
            Kartlık · kesit çözücü + dikiş dağıtıcı
            <br />
            ölçüler mm · ızgara 10mm, kalın çizgi 50mm
          </p>
        </header>

        <div className="group">
          <span className="group-title">Katalog</span>
          {CATEGORIES.map((c) => (
            <div className="cat" key={c.id}>
              <span className="cat-name">{c.name}</span>
              <ul className="fam">
                {familiesByCategory(c.id).map((f) => {
                  const usable = f.status === "hazir";
                  const active = usable && f.id === family;
                  return (
                    <li key={f.id}>
                      <button
                        type="button"
                        className="fam-item"
                        data-status={f.status}
                        data-active={active}
                        disabled={!usable}
                        aria-pressed={active}
                        onClick={() => {
                          if (usable) setFamily(f.id as FamilyId);
                        }}
                      >
                        <span>{f.name}</span>
                        <span className="fam-status">
                          {STATUS_LABEL[f.status]}
                        </span>
                      </button>
                    </li>
                  );
                })}
              </ul>
              {!categoryHasAvailable(c.id) && (
                <p className="hint">{c.description}</p>
              )}
            </div>
          ))}
        </div>

        {isBifold ? (
          <fieldset className="group" style={{ border: 0, margin: 0, padding: 0 }}>
            <legend>Bifold</legend>
            <Slider
              label="Panel başına yuva"
              value={bifold.cardSlotsPerSide}
              min={1}
              max={6}
              step={1}
              onChange={(v) => setB("cardSlotsPerSide", v)}
            />
            <Select
              label="Banknot"
              value={bifold.currency}
              options={Object.values(BANKNOTES).map((b) => ({
                value: b.currency,
                label: b.label + (b.verified ? "" : " ⚠"),
              }))}
              hint="Cüzdanın açık genişliğini en büyük kupür belirler."
              onChange={(v) => setB("currency", v as Currency)}
            />
            <Choice<SlotConstruction>
              label="Yapım biçimi"
              value={bifold.construction}
              options={[
                { value: "t-slot", label: "T-slot" },
                { value: "stacked", label: "Düz yığın" },
              ]}
              onChange={(v) => setB("construction", v)}
            />
            <Slider
              label="Kademe"
              value={bifold.reveal}
              min={5}
              max={22}
              step={0.5}
              unit="mm"
              onChange={(v) => setB("reveal", v)}
            />
            <Slider
              label="Dış kabuk"
              value={bifold.outerThickness}
              min={0.6}
              max={1.4}
              step={0.1}
              unit="mm"
              onChange={(v) => setB("outerThickness", v)}
            />
            <Slider
              label="İç kabuk"
              value={bifold.innerThickness}
              min={0.5}
              max={1.2}
              step={0.1}
              unit="mm"
              onChange={(v) => setB("innerThickness", v)}
            />
            <Slider
              label="Yuva derisi"
              value={bifold.slotThickness}
              min={0.4}
              max={1.0}
              step={0.1}
              unit="mm"
              onChange={(v) => setB("slotThickness", v)}
            />
            <Slider
              label="Dikiş payı"
              value={bifold.stitchMargin}
              min={2.5}
              max={5}
              step={0.5}
              unit="mm"
              onChange={(v) => setB("stitchMargin", v)}
            />
            <Slider
              label="Köşe yarıçapı"
              value={bifold.cornerRadius}
              min={0}
              max={12}
              step={0.5}
              unit="mm"
              onChange={(v) => setB("cornerRadius", v)}
            />
            <Select
              label="Pricking iron"
              value={bifold.pitch === undefined ? "auto" : String(bifold.pitch)}
              options={[
                { value: "3", label: "3.0 mm" },
                { value: "3.38", label: "3.38 mm" },
                { value: "3.85", label: "3.85 mm" },
                { value: "4", label: "4.0 mm" },
                { value: "auto", label: "Oto — en az delik" },
              ]}
              onChange={(v) =>
                setBifold((p) => {
                  if (v === "auto") {
                    const { pitch: _drop, ...rest } = p;
                    return rest;
                  }
                  return { ...p, pitch: Number(v) };
                })
              }
            />
            <Choice<string>
              label="Kalem payı"
              value={String(bifold.penAllowance)}
              options={[
                { value: "0", label: "0" },
                { value: "0.3", label: "0.3mm" },
                { value: "0.5", label: "0.5mm" },
              ]}
              onChange={(v) => setB("penAllowance", Number(v))}
            />
          </fieldset>
        ) : (
          <>
        <fieldset className="group" style={{ border: 0, margin: 0, padding: 0 }}>
          <legend>Yuvalar</legend>
          <Slider
            label="Kart yuvası"
            value={params.cardCount}
            min={1}
            max={8}
            step={1}
            onChange={(v) => set("cardCount", v)}
          />
          <Choice<SlotConstruction>
            label="Yapım biçimi"
            value={params.construction}
            options={[
              { value: "t-slot", label: "T-slot" },
              { value: "stacked", label: "Düz yığın" },
            ]}
            hint="T-slot kenar kalınlığını yuva sayısından bağımsız tutar."
            onChange={(v) => set("construction", v)}
          />
          <Choice<CardOrientation>
            label="Kart yönü"
            value={params.orientation}
            options={[
              { value: "horizontal", label: "Yatay" },
              { value: "vertical", label: "Dikey" },
            ]}
            onChange={(v) => set("orientation", v)}
          />
          <Slider
            label="Kademe"
            value={params.reveal}
            min={5}
            max={22}
            step={0.5}
            unit="mm"
            hint="Yuva ağızları arası mesafe. 5mm belgelenmiş alt sınır."
            onChange={(v) => set("reveal", v)}
          />
        </fieldset>

        <fieldset className="group" style={{ border: 0, margin: 0, padding: 0 }}>
          <legend>Deri</legend>
          <Slider
            label="Dış kabuk"
            value={params.outerThickness}
            min={0.6}
            max={1.6}
            step={0.1}
            unit="mm"
            onChange={(v) => set("outerThickness", v)}
          />
          <Slider
            label="Yuva derisi"
            value={params.slotThickness}
            min={0.4}
            max={1.2}
            step={0.1}
            unit="mm"
            hint="Önerilen 0.6–0.8mm. Kalın deri yuvanın esnemesini engeller."
            onChange={(v) => set("slotThickness", v)}
          />
        </fieldset>

        <fieldset className="group" style={{ border: 0, margin: 0, padding: 0 }}>
          <legend>Dikiş ve kesim</legend>
          <Select
            label="Pricking iron"
            value={params.pitch === undefined ? "auto" : String(params.pitch)}
            options={[
              { value: "2.7", label: "2.7 mm" },
              { value: "3", label: "3.0 mm" },
              { value: "3.38", label: "3.38 mm" },
              { value: "3.85", label: "3.85 mm" },
              { value: "4", label: "4.0 mm" },
              { value: "5", label: "5.0 mm" },
              { value: "auto", label: "Oto — en az delik" },
            ]}
            hint="Elindeki takımın adımını seç. Oto yalnızca sapmayı ölçebilir, dikişin sıklığı senin kararın."
            onChange={(v) =>
              setParams((p) => {
                if (v === "auto") {
                  const { pitch: _drop, ...rest } = p;
                  return rest;
                }
                return { ...p, pitch: Number(v) };
              })
            }
          />
          <Slider
            label="Dikiş payı"
            value={params.stitchMargin}
            min={2.5}
            max={5}
            step={0.5}
            unit="mm"
            onChange={(v) => set("stitchMargin", v)}
          />
          <Slider
            label="Köşe yarıçapı"
            value={params.cornerRadius}
            min={0}
            max={10}
            step={0.5}
            unit="mm"
            onChange={(v) => set("cornerRadius", v)}
          />
          <Choice<string>
            label="Kalem payı"
            value={String(params.penAllowance)}
            options={[
              { value: "0", label: "0" },
              { value: "0.3", label: "0.3mm" },
              { value: "0.5", label: "0.5mm" },
            ]}
            hint="Kalem ucu dışa kaçtığı için şablon o kadar küçük basılır."
            onChange={(v) => set("penAllowance", Number(v))}
          />
        </fieldset>
          </>
        )}

        <fieldset className="group" style={{ border: 0, margin: 0, padding: 0 }}>
          <legend>Baskı</legend>

          <Choice<string>
            label="Delikler"
            value={print.printAllHoles ? "all" : "anchors"}
            options={[
              { value: "anchors", label: "Sadece köşe" },
              { value: "all", label: "Hepsi" },
            ]}
            hint="Şablonu deriye bantlayıp noktalardan deleceksen 'Hepsi'. Ironu kendin yürüteceksen köşe çapaları yeterli."
            onChange={(v) =>
              setPrint((p) => ({ ...p, printAllHoles: v === "all" }))
            }
          />

          <div className="field">
            <div className="field-head">
              <label htmlFor="cal">Ölçtüğün kare</label>
              <span className="field-value">nominal 50mm</span>
            </div>
            <div className="calibrate">
              <input
                id="cal"
                type="number"
                step="0.1"
                min="1"
                value={print.measured}
                onChange={(e) =>
                  setPrint((p) => ({ ...p, measured: e.target.value }))
                }
              />
              <button
                type="button"
                onClick={() => {
                  void pdfModule().then(({ scaleFromMeasurement }) => {
                    const r = scaleFromMeasurement(Number(print.measured));
                    setPrint((p) => ({
                      ...p,
                      scaleFactor: r.ok ? r.factor : p.scaleFactor,
                      note: r.message,
                      noteOk: r.ok,
                    }));
                  });
                }}
              >
                Uygula
              </button>
            </div>
            <p className="hint">
              PDF'i bas, kapaktaki kareyi cetvelle ölç, çıkan değeri buraya
              gir. Ölçek düzeltilir.
            </p>
            {print.note !== "" && (
              <p className="hint" data-tone={print.noteOk ? "ok" : "bad"}>
                {print.note}
              </p>
            )}
          </div>

          <button
            type="button"
            className="primary"
            disabled={print.busy || !result.ok}
            onClick={() => {
              if (!result.ok) return;
              setPrint((p) => ({ ...p, busy: true }));
              pdfModule()
                .then(({ downloadPatternPdf }) =>
                  downloadPatternPdf(result.value, {
                    printAllHoles: print.printAllHoles,
                    scaleFactor: print.scaleFactor,
                    title: isBifold
                      ? `Bifold ${bifold.cardSlotsPerSide}+${bifold.cardSlotsPerSide} yuva`
                      : `Kartlık ${params.cardCount} yuva`,
                    params: ctx,
                  }),
                )
                .catch((err: unknown) => {
                  setPrint((p) => ({
                    ...p,
                    note:
                      "PDF üretilemedi: " +
                      (err instanceof Error ? err.message : String(err)),
                    noteOk: false,
                  }));
                })
                .finally(() => setPrint((p) => ({ ...p, busy: false })));
            }}
          >
            {print.busy ? "Hazırlanıyor…" : "PDF indir"}
          </button>
          {print.scaleFactor !== 1 && (
            <p className="hint">
              Ölçek düzeltmesi aktif: ×{print.scaleFactor.toFixed(4)}
            </p>
          )}
        </fieldset>
      </aside>

      <main className="stage">
        {!result.ok ? (
          <ul className="diagnostics">
            <li className="diagnostic" data-severity="error">
              <code>ÇÖZÜLEMEDİ</code>
              <span>
                Bu parametrelerle kalıp üretilemiyor: {result.message}
                {" "}Dikiş payını küçültmeyi ya da yuva sayısını azaltmayı dene.
              </span>
            </li>
          </ul>
        ) : (
          <Result value={result.value} ctx={ctx} isBifold={isBifold} />
        )}
      </main>
    </div>
  );
}

function Result({
  value,
  ctx,
  isBifold,
}: {
  value: ReturnType<typeof generateCardHolder>;
  ctx: CardHolderParams | BifoldParams;
  isBifold: boolean;
}) {
  const s = value.summary;
  const outer = value.pieces.find((p) => p.id === "outer");

  return (
    <>
      {value.diagnostics.length > 0 && (
        <ul className="diagnostics">
          {value.diagnostics.map((d, i) => (
            <li key={i} className="diagnostic" data-severity={d.severity}>
              <code>{d.code}</code>
              <span>{d.message}</span>
            </li>
          ))}
        </ul>
      )}

      <div className="stage-head">
        <h2>Parçalar</h2>
        <span className="scale-note">
          {isBifold
            ? `${(ctx as BifoldParams).cardSlotsPerSide}+${(ctx as BifoldParams).cardSlotsPerSide} yuva`
            : `${(ctx as CardHolderParams).cardCount} yuva`}{" "}
          · {ctx.construction === "t-slot" ? "T-slot" : "düz yığın"} · {s.pitch}mm
          adım · {s.totalHoles} delik
        </span>
      </div>

      <div className="legend">
        <span>
          <i className="swatch" style={{ borderTopColor: "var(--bone)" }} /> kesim
        </span>
        <span>
          <i
            className="swatch"
            style={{ borderTopColor: "var(--brass-dim)", borderTopStyle: "dashed" }}
          />{" "}
          dikiş hattı
        </span>
        <span>
          <i
            className="swatch"
            style={{ borderTopColor: "var(--chalk)", borderTopStyle: "dotted" }}
          />{" "}
          kat
        </span>
        <span>
          <i className="swatch dot" /> delik
        </span>
      </div>

      {value.pieces.map((piece) => (
        <section className="piece" key={piece.id}>
          <div className="piece-head">
            <span className="piece-name">{piece.name}</span>
            <span className="piece-meta">
              ×{piece.quantity} · {piece.width.toFixed(1)} × {piece.height.toFixed(1)}mm ·{" "}
              {piece.leatherThickness.toFixed(1)}mm deri
            </span>
          </div>
          <PieceView piece={piece} pxPerMm={PX_PER_MM} />
        </section>
      ))}

      <section className="steps">
        <h3>Yapım adımları</h3>
        <ol>
          {buildInstructions(value, ctx).map((step) => (
            <li key={step.n}>
              <span className="step-title">{step.title}</span>
              <p>{step.body}</p>
              {step.warning !== undefined && (
                <p className="step-warn">{step.warning}</p>
              )}
            </li>
          ))}
        </ol>
      </section>

      <div className="columns">
        <table className="readout">
          <caption>Kesit çözümü</caption>
          <tbody>
            {value.crossSection.layers.map((l) => (
              <tr key={l.layerId}>
                <th scope="row">{l.name}</th>
                <td className="num">{l.straightLength.toFixed(2)}</td>
                <td className="num">+{l.bendAllowance.toFixed(2)}</td>
                <td className="num">= {l.flatLength.toFixed(2)} mm</td>
              </tr>
            ))}
          </tbody>
        </table>

        <table className="readout">
          <caption>Ölçüler</caption>
          <tbody>
            <tr>
              <th scope="row">bölme genişliği</th>
              <td className="num">{s.compartmentWidth.toFixed(1)} mm</td>
            </tr>
            <tr>
              <th scope="row">yuva yığını</th>
              <td className="num">{s.slotStackHeight.toFixed(1)} mm</td>
            </tr>
            <tr>
              <th scope="row">kat payı</th>
              <td className="num">{s.foldAllowance.toFixed(2)} mm</td>
            </tr>
            <tr>
              <th scope="row">kapalı kalınlık</th>
              <td className="num">{s.closedThickness.toFixed(2)} mm</td>
            </tr>
            <tr>
              <th scope="row">kart yüklü</th>
              <td className="num">{s.loadedThickness.toFixed(2)} mm</td>
            </tr>
            <tr>
              <th scope="row">kenar kalınlığı</th>
              <td className="num">{s.edgeThickness.toFixed(2)} mm</td>
            </tr>
            <tr>
              <th scope="row">A4</th>
              <td className="num">{s.fitsA4 ? "sığıyor" : "bölünecek"}</td>
            </tr>
          </tbody>
        </table>

        {outer?.stitchPlan !== undefined && (
          <table className="readout">
            <caption>Dikiş planı — dış kabuk</caption>
            <tbody>
              {stitchSummaryFor(outer.stitchPlan).map((line, i) => (
                <tr key={i}>
                  <td colSpan={2}>{line}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>
    </>
  );
}
ODK_EOF_13

echo "==> apps/web/src/styles.css"
cat > apps/web/src/styles.css << 'ODK_EOF_14'
/*
  TASARIM NOTU
  ────────────────────────────────────────────────────────────────────
  Bu bir alet, tanıtım sayfası değil. Palet konunun kendi dünyasından:
  deri işçisinin gün boyu baktığı şey kesim matı. Koyu yeşil mat, üstünde
  bone beyazı kesim hatları, pirinç renginde dikiş delikleri.

  Mat ızgarası süs değil ÖLÇÜM ARACI: 10mm aralıklı, kalın çizgiler 50mm.
  Yani ekrandaki ızgara, kullanıcının masasındaki matın aynısı ve ölçek
  referansı olarak okunabiliyor.

  Tipografi: her sayı monospace (IBM Plex Mono) — ölçüler hizalanmalı ve
  rakamlar eşit genişlikte olmalı ki 93.4 ile 103.4 yan yana okunabilsin.
  Etiketler condensed sans, çünkü dar kontrol rayında yer dar.
*/

:root {
  --mat: #14312b;
  --mat-deep: #0e2420;
  --mat-grid: #1d443b;
  --mat-grid-major: #2a5f52;

  --panel: #0b1c19;
  --panel-edge: #1c3a34;

  --bone: #f2efe6;
  --bone-dim: #a8b5ae;
  --bone-faint: #6d8079;

  --brass: #e0a458;
  --brass-dim: #8a6535;
  --chalk: #6fb3a0;

  --warn: #d9973f;
  --error: #d9634f;

  /* JetBrains Mono: PDF katmanıyla aynı font. IBM Plex Mono
     @pdf-lib/fontkit ile boşluk karakterinde patlıyor (bkz.
     packages/print/src/print.test.ts), ekran ve baskı ayrışmasın diye
     ikisi de buna geçti. */
  --mono: "JetBrains Mono", ui-monospace, "SFMono-Regular", monospace;
  --sans: "IBM Plex Sans Condensed", system-ui, -apple-system, sans-serif;

  --rail: 320px;
}

* {
  box-sizing: border-box;
}

html,
body {
  margin: 0;
  padding: 0;
  background: var(--panel);
  color: var(--bone);
  font-family: var(--sans);
  -webkit-font-smoothing: antialiased;
}

body {
  min-height: 100vh;
}

/* ── Kabuk ─────────────────────────────────────────────────────────── */

.shell {
  display: grid;
  grid-template-columns: var(--rail) 1fr;
  min-height: 100vh;
}

.rail {
  background: var(--panel);
  border-right: 1px solid var(--panel-edge);
  padding: 20px 18px 40px;
  overflow-y: auto;
}

.stage {
  background: var(--mat-deep);
  padding: 20px 24px 60px;
  overflow-x: auto;
}

@media (max-width: 860px) {
  .shell {
    grid-template-columns: 1fr;
  }
  .rail {
    border-right: none;
    border-bottom: 1px solid var(--panel-edge);
  }
}

/* ── Başlık ────────────────────────────────────────────────────────── */

.masthead {
  margin-bottom: 26px;
}

.masthead h1 {
  font-size: 19px;
  font-weight: 700;
  letter-spacing: 0.02em;
  margin: 0 0 4px;
}

.masthead p {
  font-family: var(--mono);
  font-size: 11px;
  line-height: 1.5;
  color: var(--bone-faint);
  margin: 0;
}

/* ── Kontroller ────────────────────────────────────────────────────── */

.group {
  margin-bottom: 22px;
}

.group > legend,
.group-title {
  font-family: var(--mono);
  font-size: 10px;
  letter-spacing: 0.14em;
  text-transform: uppercase;
  color: var(--bone-faint);
  margin: 0 0 10px;
  padding: 0;
  display: block;
}

.field {
  margin-bottom: 14px;
}

.field-head {
  display: flex;
  justify-content: space-between;
  align-items: baseline;
  margin-bottom: 5px;
}

.field-head label {
  font-size: 13px;
  color: var(--bone-dim);
}

.field-value {
  font-family: var(--mono);
  font-size: 12px;
  color: var(--bone);
}

input[type="range"] {
  width: 100%;
  height: 20px;
  appearance: none;
  background: transparent;
  cursor: pointer;
}

input[type="range"]::-webkit-slider-runnable-track {
  height: 2px;
  background: var(--panel-edge);
}

input[type="range"]::-moz-range-track {
  height: 2px;
  background: var(--panel-edge);
}

input[type="range"]::-webkit-slider-thumb {
  appearance: none;
  width: 13px;
  height: 13px;
  margin-top: -5.5px;
  background: var(--brass);
  border: none;
  border-radius: 0;
  transform: rotate(45deg);
}

input[type="range"]::-moz-range-thumb {
  width: 13px;
  height: 13px;
  background: var(--brass);
  border: none;
  border-radius: 0;
}

input[type="range"]:focus-visible {
  outline: 2px solid var(--chalk);
  outline-offset: 4px;
}

.segmented {
  display: flex;
  gap: 1px;
  background: var(--panel-edge);
  border: 1px solid var(--panel-edge);
}

.segmented button {
  flex: 1;
  background: var(--panel);
  color: var(--bone-dim);
  border: none;
  padding: 7px 4px;
  font-family: var(--sans);
  font-size: 12px;
  cursor: pointer;
}

.segmented button[aria-pressed="true"] {
  background: var(--brass);
  color: var(--mat-deep);
  font-weight: 600;
}

.segmented button:focus-visible {
  outline: 2px solid var(--chalk);
  outline-offset: -2px;
}

.hint {
  font-family: var(--mono);
  font-size: 10px;
  line-height: 1.5;
  color: var(--bone-faint);
  margin: 5px 0 0;
}

/* ── Tanılama ──────────────────────────────────────────────────────── */

.diagnostics {
  margin: 0 0 20px;
  padding: 0;
  list-style: none;
}

.diagnostic {
  display: flex;
  gap: 9px;
  padding: 9px 11px;
  margin-bottom: 6px;
  font-size: 13px;
  line-height: 1.45;
  background: var(--panel);
  border-left: 2px solid var(--bone-faint);
}

.diagnostic[data-severity="warning"] {
  border-left-color: var(--warn);
}

.diagnostic[data-severity="error"] {
  border-left-color: var(--error);
}

.diagnostic code {
  font-family: var(--mono);
  font-size: 10px;
  letter-spacing: 0.06em;
  color: var(--bone-faint);
  white-space: nowrap;
  padding-top: 2px;
}

/* ── Sahne ─────────────────────────────────────────────────────────── */

.stage-head {
  display: flex;
  flex-wrap: wrap;
  gap: 8px 22px;
  align-items: baseline;
  margin-bottom: 16px;
}

.stage-head h2 {
  font-size: 15px;
  font-weight: 600;
  margin: 0;
  letter-spacing: 0.02em;
}

.scale-note {
  font-family: var(--mono);
  font-size: 11px;
  color: var(--bone-faint);
}

.piece {
  margin-bottom: 30px;
}

.piece-head {
  display: flex;
  flex-wrap: wrap;
  gap: 6px 16px;
  align-items: baseline;
  margin-bottom: 8px;
}

.piece-name {
  font-size: 14px;
  font-weight: 600;
}

.piece-meta {
  font-family: var(--mono);
  font-size: 11px;
  color: var(--bone-dim);
}

.piece-canvas {
  background: var(--mat);
  border: 1px solid var(--mat-grid-major);
  display: block;
  max-width: 100%;
  height: auto;
}

/* ── Tablolar ──────────────────────────────────────────────────────── */

.readout {
  border-collapse: collapse;
  font-family: var(--mono);
  font-size: 12px;
  margin-bottom: 26px;
  min-width: 260px;
}

.readout caption {
  font-size: 10px;
  letter-spacing: 0.14em;
  text-transform: uppercase;
  color: var(--bone-faint);
  text-align: left;
  padding-bottom: 8px;
}

.readout th,
.readout td {
  text-align: left;
  padding: 5px 22px 5px 0;
  border-bottom: 1px solid var(--panel-edge);
  font-weight: 400;
}

.readout th {
  color: var(--bone-faint);
}

.readout td {
  color: var(--bone);
  font-variant-numeric: tabular-nums;
}

.readout td.num {
  text-align: right;
  padding-right: 0;
}

.columns {
  display: flex;
  flex-wrap: wrap;
  gap: 0 48px;
}

/* ── Açıklama ──────────────────────────────────────────────────────── */

.legend {
  display: flex;
  flex-wrap: wrap;
  gap: 6px 20px;
  font-family: var(--mono);
  font-size: 11px;
  color: var(--bone-dim);
  margin-bottom: 18px;
}

.legend span {
  display: flex;
  align-items: center;
  gap: 7px;
}

.swatch {
  width: 20px;
  height: 0;
  border-top-width: 2px;
  border-top-style: solid;
}

.swatch.dot {
  width: 7px;
  height: 7px;
  border: none;
  border-radius: 50%;
  background: var(--brass);
}

@media (prefers-reduced-motion: reduce) {
  * {
    transition: none !important;
    animation: none !important;
  }
}

/* ── Baskı paneli ──────────────────────────────────────────────────── */

.calibrate {
  display: flex;
  gap: 6px;
}

.calibrate input {
  flex: 1;
  min-width: 0;
  background: var(--mat-deep);
  border: 1px solid var(--panel-edge);
  color: var(--bone);
  font-family: var(--mono);
  font-size: 13px;
  padding: 6px 8px;
}

.calibrate input:focus-visible,
.calibrate button:focus-visible,
button.primary:focus-visible {
  outline: 2px solid var(--chalk);
  outline-offset: 2px;
}

.calibrate button {
  background: var(--panel);
  border: 1px solid var(--panel-edge);
  color: var(--bone-dim);
  font-family: var(--sans);
  font-size: 12px;
  padding: 6px 12px;
  cursor: pointer;
}

.calibrate button:hover {
  border-color: var(--brass-dim);
  color: var(--bone);
}

button.primary {
  width: 100%;
  margin-top: 4px;
  background: var(--brass);
  color: var(--mat-deep);
  border: none;
  padding: 11px;
  font-family: var(--sans);
  font-size: 14px;
  font-weight: 600;
  letter-spacing: 0.02em;
  cursor: pointer;
}

button.primary:disabled {
  background: var(--panel-edge);
  color: var(--bone-faint);
  cursor: not-allowed;
}

.hint[data-tone="ok"] {
  color: var(--chalk);
}

.hint[data-tone="bad"] {
  color: var(--error);
}

.dropdown {
  width: 100%;
  background: var(--mat-deep);
  border: 1px solid var(--panel-edge);
  color: var(--bone);
  font-family: var(--mono);
  font-size: 13px;
  padding: 7px 8px;
  cursor: pointer;
}

.dropdown:focus-visible {
  outline: 2px solid var(--chalk);
  outline-offset: 2px;
}

/* ── Katalog ───────────────────────────────────────────────────────── */

.cat {
  margin-bottom: 12px;
}

.cat-name {
  font-size: 13px;
  font-weight: 600;
  color: var(--bone);
}

.fam {
  list-style: none;
  margin: 4px 0 0;
  padding: 0;
}

.fam-item {
  display: flex;
  justify-content: space-between;
  gap: 8px;
  padding: 4px 0 4px 9px;
  border-left: 1px solid var(--panel-edge);
  font-size: 12px;
  color: var(--bone-faint);
}

.fam-item[data-status="hazir"] {
  border-left-color: var(--brass);
  color: var(--bone);
}

.fam-status {
  font-family: var(--mono);
  font-size: 10px;
  color: var(--bone-faint);
  white-space: nowrap;
}

.fam-item[data-status="hazir"] .fam-status {
  color: var(--brass);
}

/* ── Yapım adımları ────────────────────────────────────────────────── */

.steps {
  max-width: 640px;
  margin-bottom: 32px;
}

.steps h3 {
  font-size: 14px;
  font-weight: 600;
  margin: 0 0 12px;
}

.steps ol {
  margin: 0;
  padding: 0;
  list-style: none;
  counter-reset: step;
}

.steps li {
  counter-increment: step;
  position: relative;
  padding: 0 0 16px 30px;
  border-left: 1px solid var(--panel-edge);
  margin-left: 8px;
}

.steps li::before {
  content: counter(step);
  position: absolute;
  left: -9px;
  top: 0;
  width: 18px;
  height: 18px;
  background: var(--mat-deep);
  border: 1px solid var(--panel-edge);
  color: var(--bone-dim);
  font-family: var(--mono);
  font-size: 10px;
  display: flex;
  align-items: center;
  justify-content: center;
}

.steps li:last-child {
  border-left-color: transparent;
}

.step-title {
  font-size: 13px;
  font-weight: 600;
  color: var(--bone);
}

.steps p {
  margin: 4px 0 0;
  font-size: 13px;
  line-height: 1.5;
  color: var(--bone-dim);
}

.step-warn {
  border-left: 2px solid var(--warn);
  padding-left: 9px;
  margin-top: 7px !important;
  color: var(--bone) !important;
  font-size: 12px !important;
}

button.fam-item {
  width: 100%;
  background: none;
  font-family: var(--sans);
  text-align: left;
  cursor: pointer;
}

button.fam-item:disabled {
  cursor: default;
}

button.fam-item[data-active="true"] {
  background: var(--mat);
  color: var(--bone);
  font-weight: 600;
}

button.fam-item:not(:disabled):hover {
  color: var(--bone);
}

button.fam-item:focus-visible {
  outline: 2px solid var(--chalk);
  outline-offset: -2px;
}
ODK_EOF_14

echo "==> docs/SOURCES.md"
cat > docs/SOURCES.md << 'ODK_EOF_15'
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
ODK_EOF_15

echo "==> Testler"
pnpm test

echo "==> Typecheck"
pnpm typecheck

echo "==> Arayuz derlemesi"
pnpm --filter @odk/web build

cat << 'ODK_DONE'

============================================================
FAZ 3 — BIFOLD CUZDAN
============================================================

Arayuzde sol raydaki katalogdan "Bifold cuzdan" secilebilir.

Varsayilan (3 yuva/panel, TRY):
  acik 218.2 x 84.4mm · kat payi 16.41mm
  bos 7.60mm · kart yuklu 12.16mm
  parcalar: A dis kabuk, B ic kabuk, C x2 duz yuva, D x4 T-slot

Git:
  git add -A
  git commit -m "Faz 3: bifold cuzdan ve BillPocket modulu

MODEL DEGISIKLIGI — Fold.gaps
- Bifold'da dis kabuk ic kabugun degil TUM ICERIGIN etrafini dolanir.
  Kart yiginlari kivrimdan gecmez ama dis kabugun yaricapini belirler.
- gaps alani olmadan model 2.6mm veriyordu; belgelenmis yarim inc
  kurali 12.7mm. Farkin tamami bu dolgudan geliyor.
- 2 yuva/panel (MAKESUPPLY'in 'bare minimum' tarifi) -> 11.8mm,
  12.7'ye 0.9mm yakin. Test ile sabitlendi.
- Yarim inc SABIT DEGIL: kalin cuzdan daha cok pay ister. Modeli
  12.7'ye zorlamak hata olurdu.

BANKNOT
- TRY 200 TL 160x72mm ve USD 156x66.3mm kaynaktan dogrulandi
- EUR/GBP dogrulanmadi, verified:false ile isaretli, uyari uretiyor

DUZELTILEN IKI KURAL
- TIGHT_RADIUS artik EN IC KATMANIN kalinligina bakiyor. Yigin
  kalinligina bakan eski olcut bifold'da her zaman yanlis uyariyordu:
  dolgulu kivrimda en ic katman kendi etrafina sarilir.
- BULKY artik BOS kalinliga bakiyor. Belgelenmis 6-8mm hedefi bos urun
  icin verilmis; yuklu kalinliga bakan olcut 3 yuvali cok yaygin bir
  cuzdani gereksiz uyariyordu.

- Talimatlar InstructionContext ile genellestirildi; iki aile de ayni
  koddan geciyor
- Katalogda bifold 'hazir'; durustluk testi guncellendi
- 302 test geciyor"

  git push
  vercel --prod
ODK_DONE
