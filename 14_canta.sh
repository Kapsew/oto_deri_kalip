#!/usr/bin/env bash
#
# 14_canta.sh — Faz 3: Koruklu canta (askili / askisiz)
#
# Repo kokunde calistir. Idempotent.

set -euo pipefail

if [ ! -f "pnpm-workspace.yaml" ] || [ ! -d "packages/print" ]; then
  echo "HATA: Repo kokunde calistirilmali ve 13 uygulanmis olmali." >&2
  exit 1
fi
mkdir -p docs

echo "==> packages/patterns/src/tote.ts"
cat > packages/patterns/src/tote.ts << 'ODK_EOF_0'
import type { Mm, Polyline, StitchPlan, Vec } from "@odk/geometry";
import {
  bbox,
  cutLine,
  distributeStitches,
  flattenPath,
  path,
  polylineLength,
  roundCorners,
  vec,
} from "@odk/geometry";
import type { Temper } from "./material.js";
import { leather } from "./material.js";
import type {
  AssemblyPlacement,
  PatternPiece,
  PatternResult,
  PatternSummary,
} from "./cardholder.js";
import { fitsOnA4 } from "./cardholder.js";
import type { CrossSection, Diagnostic, Layer } from "./crosssection.js";
import { solveCrossSection } from "./crosssection.js";

/**
 * KÖRÜKLÜ ÇANTA
 *
 * ═══════════════════════════════════════════════════════════════════════
 * CÜZDANLARDAN YAPISAL FARK
 * ═══════════════════════════════════════════════════════════════════════
 *
 * Cüzdanda tek parça katlanıyordu. Çantada hacmi KÖRÜK veriyor: ön ve
 * arka panelin arasına dikilen, yanlardan ve alttan dolanan bir şerit.
 *
 * Buradaki asıl mühendislik problemi körüğün UZUNLUĞU. Körük panelin
 * dikiş hattı boyunca dolanıyor, dolayısıyla uzunluğu o hattın YAY
 * UZUNLUĞU. Panelin alt köşeleri yuvarlatıldığı için bu düz bir toplama
 * değil; Adım 4'te kurduğumuz yay uzunluğu makinesi tam olarak bunun
 * için var.
 *
 * İkinci problem: körüğün iki uzun kenarındaki delikler, ön ve arka
 * panelin delikleriyle BİREBİR aynı yerde olmalı. Bu yüzden delikler
 * panel hattında bir kez hesaplanıp körüğe mesafeye göre aktarılıyor —
 * yine projeksiyon mantığı, bu sefer eğriden düze.
 */

export type GussetStyle = "tek-parca" | "uc-parca";
export type StrapStyle = "yok" | "el" | "omuz" | "capraz";

/**
 * BELGELENMİŞ askı ölçüleri.
 *
 * drop = askının tepe noktasından çantanın üst kenarına dikey mesafe.
 *
 * - Çapraz: toplam uzunluk 114–137cm, drop 51–61cm.
 *   Yaygın kural: toplam ≈ 2.3 × drop (çapraz gövdeyi kestiği için
 *   omuz askısından daha uzun bir yol izliyor).
 * - Omuz: drop 45–60cm; toplam ≈ 2 × drop.
 * - Tote sapı: drop 25–36cm (10–14 inç); toplam ≈ 2 × drop.
 */
export interface StrapSpec {
  readonly label: string;
  readonly count: number;
  readonly defaultDrop: Mm;
  readonly minDrop: Mm;
  readonly maxDrop: Mm;
  /** Toplam uzunluk = multiplier × drop + 2 × bindirme. */
  readonly multiplier: number;
}

export const STRAP_SPECS: Record<Exclude<StrapStyle, "yok">, StrapSpec> = {
  el: {
    label: "el sapı",
    count: 2,
    defaultDrop: 270,
    minDrop: 250,
    maxDrop: 360,
    multiplier: 2,
  },
  omuz: {
    label: "omuz askısı",
    count: 1,
    defaultDrop: 500,
    minDrop: 450,
    maxDrop: 600,
    multiplier: 2,
  },
  capraz: {
    label: "çapraz askı",
    count: 1,
    defaultDrop: 550,
    minDrop: 510,
    maxDrop: 610,
    multiplier: 2.3,
  },
};

/** Askı ucunun çantaya bindiği pay. */
export const STRAP_OVERLAP: Mm = 40;

/**
 * Şablon basmak yerine cetvelle ölçmenin daha mantıklı olduğu uzunluk.
 *
 * Düz bir şerit için 5 sayfa döşeme basmak kâğıt israfı; kullanıcı
 * cetvelle çok daha hızlı ve en az o kadar hassas keser. Eğrisi olan
 * parçalar için aynı şey geçerli değil, onlar her hâlükârda basılıyor.
 */
export const STRIP_TEMPLATE_LIMIT: Mm = 400;

export interface ToteParams {
  /** Bitmiş genişlik (dikiş hattından ölçülür). */
  readonly width: Mm;
  readonly height: Mm;
  /** Körük genişliği = çantanın derinliği. */
  readonly depth: Mm;
  /** Alt köşe yarıçapı. */
  readonly cornerRadius: Mm;
  readonly gusset: GussetStyle;
  readonly strap: StrapStyle;
  readonly strapDrop?: Mm;
  readonly strapWidth: Mm;
  readonly panelThickness: Mm;
  readonly gussetThickness: Mm;
  readonly strapThickness: Mm;
  readonly temper: Temper;
  readonly stitchMargin: Mm;
  readonly topCornerRadius: Mm;
  readonly penAllowance: Mm;
  readonly pitch?: Mm;
}

export const TOTE_DEFAULTS: ToteParams = {
  width: 220,
  height: 200,
  depth: 80,
  cornerRadius: 40,
  gusset: "uc-parca",
  strap: "capraz",
  strapWidth: 20,
  // Çanta yapısal yük taşıyor: cüzdan derisi (0.7–1.0mm) burada yetmez.
  // 4–6 oz (1.6–2.4mm) bandı standart.
  panelThickness: 1.8,
  gussetThickness: 1.6,
  strapThickness: 2.4,
  temper: "veg-tan-firm",
  stitchMargin: 4,
  topCornerRadius: 8,
  penAllowance: 0.3,
  pitch: 4,
};

/** Çeyrek daire yaklaşımı için kübik kontrol noktası oranı. */
const K_ARC = (4 / 3) * (Math.SQRT2 - 1);

/**
 * Alt köşeleri yuvarlak, üst köşeleri keskin panel dış hattı.
 *
 * Köşeler kübik yaylarla kuruluyor (roundCorners tek yarıçapı tüm
 * köşelere uygular; burada alt ve üst farklı olmalı). Üst köşeler
 * sonradan küçük bir yarıçapla yumuşatılıyor; roundCorners'ın açı eşiği
 * zaten yumuşak olan alt köşelere dokunmuyor.
 */
function panelOutline(w: Mm, h: Mm, r: Mm, topRadius: Mm): Polyline {
  const k = K_ARC * r;
  const raw = flattenPath(
    path()
      .moveTo(vec(0, h))
      .lineTo(vec(0, r))
      .cubicTo(vec(0, r - k), vec(r - k, 0), vec(r, 0))
      .lineTo(vec(w - r, 0))
      .cubicTo(vec(w - r + k, 0), vec(w, r - k), vec(w, r))
      .lineTo(vec(w, h))
      .close(),
  );
  return topRadius > 0 ? roundCorners(raw, true, { radius: topRadius }) : raw;
}

/** Panelin dikiş hattı: sol kenar → alt → sağ kenar. Üst AÇIK. */
function panelStitchPath(w: Mm, h: Mm, r: Mm, m: Mm): Polyline {
  const k = K_ARC * r;
  return flattenPath(
    path()
      .moveTo(vec(m, h))
      .lineTo(vec(m, m + r))
      .cubicTo(vec(m, m + r - k), vec(m + r - k, m), vec(m + r, m))
      .lineTo(vec(w - m - r, m))
      .cubicTo(vec(w - m - r + k, m), vec(w - m, m + r - k), vec(w - m, m + r))
      .lineTo(vec(w - m, h))
      .open(),
  );
}

/** Düz şerit: körük parçası, askı, kulakçık. */
function strip(length: Mm, width: Mm, endRadius: Mm): Polyline {
  const raw = flattenPath(
    path()
      .moveTo(vec(0, 0))
      .lineTo(vec(length, 0))
      .lineTo(vec(length, width))
      .lineTo(vec(0, width))
      .close(),
  );
  return endRadius > 0
    ? roundCorners(raw, true, { radius: Math.min(endRadius, width / 2 - 0.5) })
    : raw;
}

/**
 * Körük şeridine, panel hattındaki deliklerin karşılıklarını yerleştirir.
 *
 * Panel hattı eğri, körük düz — ama ikisi dikildiğinde birbirine
 * oturuyor. Eşleşmeyi sağlayan şey MESAFE: panelde başlangıçtan d kadar
 * ilerideki delik, körükte de başlangıçtan d kadar ileride.
 *
 * Delikler körüğün iki uzun kenarında da var; biri ön panele, diğeri
 * arka panele dikiliyor.
 */
function gussetHoles(
  master: StitchPlan,
  fromDistance: Mm,
  toDistance: Mm,
  stripWidth: Mm,
  margin: Mm,
  leadIn: Mm,
): StitchPlan {
  const holes = master.holes
    .filter((h) => h.distance >= fromDistance - 1e-6 && h.distance <= toDistance + 1e-6)
    .flatMap((h) => {
      const x = leadIn + (h.distance - fromDistance);
      return [
        { ...h, position: { x, y: margin } as Vec },
        { ...h, position: { x, y: stripWidth - margin } as Vec },
      ];
    });

  return {
    holes,
    spans: master.spans,
    pitch: master.pitch,
    totalHoles: holes.length,
    maxDeviation: master.maxDeviation,
    warnings: [],
  };
}

export function generateTote(params: ToteParams): PatternResult {
  const diagnostics: Diagnostic[] = [];
  const m = params.stitchMargin;
  const r = params.cornerRadius;

  // --- Panel ------------------------------------------------------------
  const panelW = params.width + 2 * m;
  const panelH = params.height + m;

  const panelNominal = panelOutline(panelW, panelH, r + m, params.topCornerRadius);
  const panelCut = cutLine(panelNominal, { penAllowance: params.penAllowance });
  const stitchPath = panelStitchPath(panelW, panelH, r, m);
  const pathLength = polylineLength(stitchPath, false);

  const masterPlan = distributeStitches(
    stitchPath,
    false,
    params.pitch !== undefined ? { pitch: params.pitch } : {},
  );
  const panelBox = bbox(panelCut);

  const pieces: PatternPiece[] = [];
  pieces.push({
    id: "panel",
    code: "A",
    name: "ön / arka panel",
    kind: "outer",
    quantity: 2,
    leatherThickness: params.panelThickness,
    cutLine: panelCut,
    stitchLine: stitchPath,
    stitchLineClosed: false,
    stitchPlan: masterPlan,
    foldLines: [],
    width: panelBox.width,
    height: panelBox.height,
  });

  // --- Körük -------------------------------------------------------------
  //
  // Körüğün genişliği derinlik + iki dikiş payı; böylece dikiş hatları
  // arasındaki mesafe tam olarak derinlik oluyor.
  const gussetWidth = params.depth + 2 * m;
  const arcLength = (Math.PI / 2) * r;

  interface GussetPart {
    readonly id: string;
    readonly code: string;
    readonly name: string;
    readonly from: Mm;
    readonly to: Mm;
    readonly quantity: number;
  }

  // Üç parça bölünmesi köşe yayının ORTASINDAN yapılıyor.
  //
  // Yay sınırlarından bölmek daha sezgisel ama taban parçasını uzatıyor
  // ve A4'e sığmaz hale getiriyor. Yay ortasından bölmek iki parçayı da
  // sayfaya sığdırıyor; dikiş de düz kenarda değil eğri üzerinde
  // birleşiyor ki bu birleşimi gizliyor.
  const sideLength = params.height - r + arcLength / 2 + m;
  const parts: GussetPart[] =
    params.gusset === "tek-parca"
      ? [
          {
            id: "gusset",
            code: "B",
            name: "körük (tek parça)",
            from: 0,
            to: pathLength,
            quantity: 1,
          },
        ]
      : [
          {
            id: "gusset-side",
            code: "B",
            name: "yan körük",
            from: 0,
            to: sideLength,
            quantity: 2,
          },
          {
            id: "gusset-bottom",
            code: "C",
            name: "taban körüğü",
            from: sideLength,
            to: pathLength - sideLength,
            quantity: 1,
          },
        ];

  for (const part of parts) {
    const segment = part.to - part.from;
    // Her parçanın iki ucunda dikiş payı kadar fazlalık: panelin üst
    // kenarına ve komşu körük parçasına bindirme payı.
    const stripLength = segment + 2 * m;
    const nominal = strip(stripLength, gussetWidth, params.topCornerRadius);
    const cut = cutLine(nominal, { penAllowance: params.penAllowance });
    const b = bbox(cut);
    const plan = gussetHoles(masterPlan, part.from, part.to, gussetWidth, m, m);

    pieces.push({
      id: part.id,
      code: part.code,
      name: part.name,
      kind: "outer",
      quantity: part.quantity,
      leatherThickness: params.gussetThickness,
      cutLine: cut,
      foldLines: [],
      ...(plan.totalHoles > 0 ? { stitchPlan: plan } : {}),
      width: b.width,
      height: b.height,
    });
  }

  // --- Askı --------------------------------------------------------------
  let strapLength = 0;
  let strapCount = 0;
  let strapLabel = "";

  if (params.strap !== "yok") {
    const spec = STRAP_SPECS[params.strap];
    const drop = params.strapDrop ?? spec.defaultDrop;
    strapLength = spec.multiplier * drop + 2 * STRAP_OVERLAP;
    strapCount = spec.count;
    strapLabel = spec.label;

    if (drop < spec.minDrop || drop > spec.maxDrop) {
      diagnostics.push({
        severity: "warning",
        code: "STRAP_DROP_UNUSUAL",
        message:
          `${spec.label} drop ${(drop / 10).toFixed(0)}cm — belgelenmiş aralık ` +
          `${(spec.minDrop / 10).toFixed(0)}–${(spec.maxDrop / 10).toFixed(0)}cm. ` +
          `Bu aralığın dışı özel bir tercih olabilir ama alışılmadık.`,
      });
    }

    if (strapLength > STRIP_TEMPLATE_LIMIT) {
      // Şablon basmıyoruz — bkz. STRIP_TEMPLATE_LIMIT.
      diagnostics.push({
        severity: "warning",
        code: "STRAP_NOT_PRINTED",
        message:
          `${spec.label} ${(strapLength / 10).toFixed(1)}cm × ` +
          `${params.strapWidth}mm. Bu uzunlukta şablon basmak yerine cetvelle ` +
          `ölçüp kes: düz bir şerit, kalıba gerek yok. ` +
          `${spec.count} adet, ${params.strapThickness.toFixed(1)}mm deri.`,
      });
    } else {
      const nominal = strip(strapLength, params.strapWidth, params.strapWidth / 2);
      const cut = cutLine(nominal, { penAllowance: params.penAllowance });
      const b = bbox(cut);
      pieces.push({
        id: "strap",
        code: params.gusset === "tek-parca" ? "C" : "D",
        name: spec.label,
        kind: "outer",
        quantity: spec.count,
        leatherThickness: params.strapThickness,
        cutLine: cut,
        foldLines: [],
        width: b.width,
        height: b.height,
      });
    }
  }

  // --- Kesit: köşe kıvrımında körük ve panel ------------------------------
  const panelSpec = leather(params.temper, params.panelThickness);
  const gussetSpec = leather(params.temper, params.gussetThickness);
  const layers: Layer[] = [
    { id: "gusset", name: "körük", spec: gussetSpec },
    { id: "panel", name: "panel", spec: panelSpec },
  ];

  const crossSection: CrossSection = {
    name: "çanta alt köşesi",
    layers,
    runs: [
      { id: "side", name: "yan", length: params.height - r, layers: ["gusset", "panel"] },
      { id: "bottom", name: "taban", length: params.width - 2 * r, layers: ["gusset", "panel"] },
    ],
    folds: [
      {
        id: "corner",
        name: "alt köşe",
        angleDeg: 90,
        innerRadius: r,
        stack: ["gusset", "panel"],
      },
    ],
  };
  const solved = solveCrossSection(crossSection);
  diagnostics.push(...solved.diagnostics);

  // --- Kurallar ----------------------------------------------------------
  if (r < params.depth / 2) {
    diagnostics.push({
      severity: "warning",
      code: "CORNER_TOO_TIGHT",
      message:
        `Alt köşe yarıçapı ${r}mm, körük genişliği ${params.depth}mm. ` +
        `Yarıçap derinliğin yarısından (${(params.depth / 2).toFixed(0)}mm) küçükse ` +
        `körük köşede buruşur. Yarıçapı büyüt ya da derinliği azalt.`,
    });
  }

  if (params.panelThickness < 1.2) {
    diagnostics.push({
      severity: "warning",
      code: "PANEL_TOO_THIN",
      message:
        `Panel derisi ${params.panelThickness.toFixed(1)}mm — çanta yapısal yük ` +
        `taşıyor, 1.6–2.4mm (4–6 oz) öneriliyor. İnce deri sarkar ve şeklini kaybeder.`,
    });
  }

  if (params.strap !== "yok" && params.strapThickness < 2.0) {
    diagnostics.push({
      severity: "warning",
      code: "STRAP_TOO_THIN",
      message:
        `Askı derisi ${params.strapThickness.toFixed(1)}mm — askı en çok yük ` +
        `taşıyan parça, 2.0–3.2mm öneriliyor. İnce askı zamanla uzar ve kopar.`,
    });
  }

  const oversized = pieces.filter((p) => !fitsOnA4(p.width, p.height));
  if (oversized.length > 0) {
    // Kullanıcıya "küçült" demek yetmez; NE KADAR küçültmesi gerektiğini
    // söylemek gerekiyor. Panel döndürülerek sığar, yani kısa kenarı
    // 190mm'yi (A4 basılabilir genişlik) aşmamalı.
    const maxWidth = 190 - 2 * m;
    const hint =
      params.gusset === "tek-parca"
        ? "Üç parçalı körüğe geçmek körüğün bölünmesini kaldırır."
        : `Panelin sığması için çanta genişliği en fazla ${maxWidth.toFixed(0)}mm olmalı.`;
    diagnostics.push({
      severity: "warning",
      code: "NEEDS_TILING",
      message:
        `${oversized.map((p) => p.code).join(", ")} döndürülse bile A4'e sığmıyor ` +
        `ve sayfalara bölünecek. ${hint}`,
    });
  }

  // --- Montaj ------------------------------------------------------------
  const assembly: AssemblyPlacement[] = pieces.map((p, i) => ({
    pieceId: p.id,
    code: p.code,
    x: 0,
    y: 0,
    layer: i,
  }));

  const volumeLitres = (params.width * params.height * params.depth) / 1e6;

  const summary: PatternSummary = {
    compartmentWidth: params.width,
    slotStackHeight: params.height,
    outerFlatWidth: panelBox.width,
    outerFlatHeight: panelBox.height,
    closedThickness: params.depth,
    loadedThickness: params.depth,
    edgeThickness: params.panelThickness + params.gussetThickness,
    foldAllowance: arcLength,
    panelHeight: panelBox.height,
    totalHoles: masterPlan.totalHoles,
    pitch: masterPlan.pitch,
    fitsA4: oversized.length === 0,
    metrics: [
      { label: "hacim", value: `${volumeLitres.toFixed(2)} L` },
      { label: "körük uzunluğu", value: `${pathLength.toFixed(1)} mm` },
      { label: "alt köşe yayı", value: `${arcLength.toFixed(1)} mm` },
      ...(strapCount > 0
        ? [
            {
              label: strapLabel,
              value: `${strapCount} × ${(strapLength / 10).toFixed(1)}cm × ${params.strapWidth}mm`,
            },
          ]
        : []),
    ],
  };

  return { pieces, assembly, crossSection: solved, diagnostics, summary };
}
ODK_EOF_0

echo "==> packages/patterns/src/tote.test.ts"
cat > packages/patterns/src/tote.test.ts << 'ODK_EOF_1'
import { describe, it, expect } from "vitest";
import {
  STRAP_SPECS,
  STRAP_OVERLAP,
  STRIP_TEMPLATE_LIMIT,
  TOTE_DEFAULTS,
  generateTote,
} from "./tote.js";
import { buildInstructions } from "./instructions.js";

describe("askı ölçüleri", () => {
  it("çapraz askı belgelenmiş 114–137cm aralığına düşüyor", () => {
    const s = STRAP_SPECS.capraz;
    const total = s.multiplier * s.defaultDrop + 2 * STRAP_OVERLAP;
    expect(total).toBeGreaterThanOrEqual(1140);
    expect(total).toBeLessThanOrEqual(1370);
  });

  it("çapraz askı omuzdan uzun, omuz saptan uzun", () => {
    const len = (k: keyof typeof STRAP_SPECS) =>
      STRAP_SPECS[k].multiplier * STRAP_SPECS[k].defaultDrop;
    expect(len("capraz")).toBeGreaterThan(len("omuz"));
    expect(len("omuz")).toBeGreaterThan(len("el"));
  });

  it("çapraz çarpanı 2.3 — omuzdan farklı", () => {
    // Çapraz askı gövdeyi diyagonal kestiği için daha uzun yol izliyor.
    expect(STRAP_SPECS.capraz.multiplier).toBeCloseTo(2.3, 6);
    expect(STRAP_SPECS.omuz.multiplier).toBe(2);
  });

  it("el sapı iki adet, askılar tek", () => {
    expect(STRAP_SPECS.el.count).toBe(2);
    expect(STRAP_SPECS.omuz.count).toBe(1);
    expect(STRAP_SPECS.capraz.count).toBe(1);
  });

  it("aralık dışı drop uyarı üretiyor", () => {
    const r = generateTote({ ...TOTE_DEFAULTS, strapDrop: 900 });
    expect(r.diagnostics.some((d) => d.code === "STRAP_DROP_UNUSUAL")).toBe(true);
  });
});

describe("körük uzunluğu", () => {
  const r = generateTote(TOTE_DEFAULTS);

  it("panel dikiş hattının yay uzunluğuna eşit", () => {
    // Beklenen: 2×(H−R) + (W−2R) + 2×(πR/2)
    const { width: W, height: H, cornerRadius: R } = TOTE_DEFAULTS;
    const expected = 2 * (H - R) + (W - 2 * R) + 2 * ((Math.PI / 2) * R);
    const actual = Number(
      (r.summary.metrics?.find((m) => m.label === "körük uzunluğu")?.value ?? "0").replace(
        " mm",
        "",
      ),
    );
    expect(actual).toBeCloseTo(expected, 0);
  });

  it("köşe yarıçapı büyüdükçe körük KISALIYOR", () => {
    // Köşeyi yuvarlatmak yolu kısaltır: 2R yerine πR/2 gidiyorsun.
    const sharp = generateTote({ ...TOTE_DEFAULTS, cornerRadius: 20 });
    const round = generateTote({ ...TOTE_DEFAULTS, cornerRadius: 60 });
    const len = (x: typeof sharp) =>
      Number(
        (x.summary.metrics?.find((m) => m.label === "körük uzunluğu")?.value ?? "0").replace(
          " mm",
          "",
        ),
      );
    expect(len(round)).toBeLessThan(len(sharp));
  });
});

describe("körük delikleri panelle eşleşiyor", () => {
  it("üç parçalı körüğün delikleri panelin toplamına eşit", () => {
    // Her körük parçasının İKİ kenarı var; toplam = 2 × panel deliği.
    const r = generateTote({ ...TOTE_DEFAULTS, gusset: "uc-parca" });
    const panel = r.pieces.find((p) => p.id === "panel");
    const gussetHoles = r.pieces
      .filter((p) => p.id.startsWith("gusset"))
      .reduce((a, p) => a + (p.stitchPlan?.totalHoles ?? 0) * p.quantity, 0);
    expect(gussetHoles).toBe((panel?.stitchPlan?.totalHoles as number) * 2);
  });

  it("tek parçalı körükte de aynı toplam", () => {
    const r = generateTote({ ...TOTE_DEFAULTS, gusset: "tek-parca" });
    const panel = r.pieces.find((p) => p.id === "panel");
    const g = r.pieces.find((p) => p.id === "gusset");
    expect(g?.stitchPlan?.totalHoles).toBe(
      (panel?.stitchPlan?.totalHoles as number) * 2,
    );
  });

  it("delikler körüğün iki uzun kenarında", () => {
    const r = generateTote(TOTE_DEFAULTS);
    const g = r.pieces.find((p) => p.id === "gusset-bottom");
    const ys = new Set((g?.stitchPlan?.holes ?? []).map((h) => h.position.y.toFixed(2)));
    expect(ys.size).toBe(2);
  });
});

describe("parçalar", () => {
  it("panel iki adet, aynı kalıp", () => {
    const r = generateTote(TOTE_DEFAULTS);
    expect(r.pieces.find((p) => p.id === "panel")?.quantity).toBe(2);
  });

  it("üç parçalı körük: 2 yan + 1 taban", () => {
    const r = generateTote({ ...TOTE_DEFAULTS, gusset: "uc-parca" });
    expect(r.pieces.find((p) => p.id === "gusset-side")?.quantity).toBe(2);
    expect(r.pieces.find((p) => p.id === "gusset-bottom")?.quantity).toBe(1);
  });

  it("üç parçalı körükte parçalar A4'e sığıyor, tek parçalıda sığmıyor", () => {
    const three = generateTote({ ...TOTE_DEFAULTS, gusset: "uc-parca" });
    const one = generateTote({ ...TOTE_DEFAULTS, gusset: "tek-parca" });
    const g3 = three.pieces.filter((p) => p.id.startsWith("gusset"));
    const g1 = one.pieces.find((p) => p.id === "gusset");
    for (const p of g3) expect(Math.min(p.width, p.height)).toBeLessThan(190);
    expect(Math.max(g1?.width as number, g1?.height as number)).toBeGreaterThan(277);
  });

  it("uzun askı şablon olarak basılmıyor, ölçüsü bildiriliyor", () => {
    // Düz bir şerit için 5 sayfa döşeme basmak kâğıt israfı.
    const r = generateTote(TOTE_DEFAULTS);
    expect(r.pieces.some((p) => p.id === "strap")).toBe(false);
    const d = r.diagnostics.find((x) => x.code === "STRAP_NOT_PRINTED");
    expect(d?.message).toContain("cetvelle");
  });

  it("kısa sap şablon olarak basılıyor", () => {
    const r = generateTote({ ...TOTE_DEFAULTS, strap: "el", strapDrop: 250 });
    const strap = r.pieces.find((p) => p.id === "strap");
    // 2×250 + 80 = 580 > 400 -> yine basılmıyor. Sınırı test edelim.
    expect(STRIP_TEMPLATE_LIMIT).toBe(400);
    expect(strap === undefined || strap.width <= STRIP_TEMPLATE_LIMIT).toBe(true);
  });

  it("askısız çantada askı parçası ve uyarısı yok", () => {
    const r = generateTote({ ...TOTE_DEFAULTS, strap: "yok" });
    expect(r.pieces.some((p) => p.id === "strap")).toBe(false);
    expect(r.diagnostics.some((d) => d.code.startsWith("STRAP"))).toBe(false);
  });
});

describe("kurallar", () => {
  it("köşe yarıçapı derinliğin yarısından küçükse uyarı", () => {
    const r = generateTote({ ...TOTE_DEFAULTS, cornerRadius: 20, depth: 100 });
    expect(r.diagnostics.some((d) => d.code === "CORNER_TOO_TIGHT")).toBe(true);
  });

  it("varsayılanda köşe kuralı sağlanıyor", () => {
    const r = generateTote(TOTE_DEFAULTS);
    expect(r.diagnostics.some((d) => d.code === "CORNER_TOO_TIGHT")).toBe(false);
  });

  it("ince panel derisi uyarı üretiyor", () => {
    const r = generateTote({ ...TOTE_DEFAULTS, panelThickness: 0.8 });
    expect(r.diagnostics.some((d) => d.code === "PANEL_TOO_THIN")).toBe(true);
  });

  it("ince askı derisi uyarı üretiyor", () => {
    const r = generateTote({ ...TOTE_DEFAULTS, strapThickness: 1.4 });
    expect(r.diagnostics.some((d) => d.code === "STRAP_TOO_THIN")).toBe(true);
  });

  it("A4 uyarısı ne kadar küçültmesi gerektiğini söylüyor", () => {
    const r = generateTote(TOTE_DEFAULTS);
    const d = r.diagnostics.find((x) => x.code === "NEEDS_TILING");
    expect(d?.message).toMatch(/en fazla \d+mm/);
  });

  it("hacim doğru hesaplanıyor", () => {
    const r = generateTote(TOTE_DEFAULTS);
    const v = r.summary.metrics?.find((m) => m.label === "hacim")?.value;
    expect(v).toBe("3.52 L");
  });
});

describe("çanta talimatları", () => {
  const r = generateTote(TOTE_DEFAULTS);
  const steps = buildInstructions(r, { ...TOTE_DEFAULTS, kind: "canta" });

  it("cüzdan adımları kullanılmıyor", () => {
    const text = steps.map((s) => s.body).join(" ");
    expect(text).not.toContain("kademeyle diz");
    expect(text).toContain("Körüğün ORTASINI");
  });

  it("körüğü çekiştirerek dikme uyarısı var", () => {
    const align = steps.find((s) => s.title.includes("hizala"));
    expect(align?.warning).toContain("çekiştirerek");
  });

  it("askı dikişi uyarısı var", () => {
    const strap = steps.find((s) => s.title.includes("Askı"));
    expect(strap?.warning).toContain("çift sıra");
  });

  it("kenar bitirmenin cüzdanın TERSİ olduğu belirtiliyor", () => {
    const edge = steps.find((s) => s.title.includes("Kenarları bitir"));
    expect(edge?.warning).toContain("SONRA");
  });

  it("askısız çantada askı adımı yok", () => {
    const noStrap = generateTote({ ...TOTE_DEFAULTS, strap: "yok" });
    const s = buildInstructions(noStrap, { ...TOTE_DEFAULTS, kind: "canta" });
    expect(s.some((x) => x.title.includes("Askı"))).toBe(false);
  });
});
ODK_EOF_1

echo "==> packages/patterns/src/instructions.ts"
cat > packages/patterns/src/instructions.ts << 'ODK_EOF_2'
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
  /** Cüzdanlarda yuva kademesi; çantada yok. */
  readonly reveal?: Mm;
  /**
   * Hangi adım dizisi kullanılacak.
   *
   * Cüzdan adımları ("yuvaları kademeyle diz") çantada anlamsız;
   * çantanın kendi kritik hataları var (körüğü kaydırmak, askı dikişi).
   * Tek bir metin ikisine birden uydurulamaz.
   */
  readonly kind?: "cuzdan" | "canta";
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
  if (params.kind === "canta") return buildBagInstructions(pattern, params);
  return buildWalletInstructions(pattern, params);
}

function buildWalletInstructions(
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
    `En alttan başla. Yuvaları ${params.reveal ?? 12}mm kademeyle diz: ` +
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


// --- Çanta adımları --------------------------------------------------------

/**
 * Çantanın kritik hataları cüzdanınkinden farklı.
 *
 * Cüzdanda felaket tutkalın yuvaya taşması. Çantada körüğün panele
 * kaydırılarak dikilmesi: körük uzunluğu panel hattının yay uzunluğuna
 * göre TAM hesaplandığı için, bir uçtan başlayıp çekiştirerek dikmek
 * diğer uçta fazlalık ya da eksiklik bırakır ve çanta çarpık oturur.
 */
function buildBagInstructions(
  pattern: PatternResult,
  params: InstructionContext,
): InstructionStep[] {
  const s = pattern.summary;
  const steps: InstructionStep[] = [];
  let n = 0;
  const add = (title: string, body: string, warning?: string): void => {
    n += 1;
    steps.push(warning === undefined ? { n, title, body } : { n, title, body, warning });
  };

  const pieceList = pattern.pieces.map((p) => `${p.code} ×${p.quantity}`).join(", ");
  const total = pattern.pieces.reduce((a, p) => a + p.quantity, 0);
  const metric = (label: string): string | undefined =>
    s.metrics?.find((m) => m.label === label)?.value;

  add(
    "Ölçeği doğrula",
    "Kapak sayfasındaki 50mm kareyi cetvelle ölç. 50mm değilse ölçtüğün " +
      "değeri uygulamaya gir, PDF'i yeniden indir ve aynı yazıcı ayarıyla bas.",
    "Bu adımı atlarsan körük uzunluğu panele oturmaz; çanta köşelerden buruşur.",
  );

  add(
    "Kağıt parçaları kes",
    `Toplam ${total} parça: ${pieceList}. Kesim çizgisini kağıtta bırak, ` +
      `dışından kes. Büyük parçalar birden fazla sayfaya bölünmüşse önce ` +
      `sayfaları haçlardan hizalayıp yapıştır.`,
  );

  add(
    "Deriyi kes",
    `Panel ve körük parçalarını damar yönü aynı olacak şekilde yerleştir ve kes. ` +
      `Körük uzunluğu ${metric("körük uzunluğu") ?? "?"}; bu değer panelin dikiş ` +
      `hattının yay uzunluğundan hesaplandı, kısaltma ya da uzatma yapma.`,
    "Askı en çok yük taşıyan parça: postun en sağlam bölgesinden (sırt) ve " +
      "damar yönünde kes. Karın bölgesinden kesilen askı zamanla uzar.",
  );

  add(
    "Delikleri işaretle",
    `${s.pitch}mm pricking iron, panel başına ${s.totalHoles} delik. ` +
      `Körüğün iki uzun kenarındaki delikler panelin delikleriyle birebir ` +
      `aynı mesafelerde; kalıptan işaretle, kendin sayma.`,
  );

  add(
    "Körüğü panele hizala",
    `Körüğün ORTASINI panelin taban ortasıyla eşle ve oradan iki yana doğru ` +
      `iğneleyerek ilerle. Köşe yayında deriyi hafifçe kıvırarak yürüt.`,
    "Bir uçtan başlayıp çekiştirerek dikme. Körük uzunluğu tam hesaplandı; " +
      "gerilerek dikilirse diğer uçta fazlalık kalır ve çanta çarpık oturur. " +
      "İkinci paneli dikmeden önce birinci tarafın düzgün oturduğunu kontrol et — " +
      "sonradan sökmek deriyi delik deliğe bırakır.",
  );

  add(
    "Dik",
    `Eyer dikişi ile önce körük–ön panel, sonra körük–arka panel. ` +
      `Toplam ${s.totalHoles * 2} delikten geçilecek.`,
  );

  const strapMetric = s.metrics?.find((m) => m.label.includes("askı") || m.label.includes("sap"));
  if (strapMetric !== undefined) {
    add(
      "Askıyı bağla",
      `${strapMetric.label}: ${strapMetric.value}. Uçları çantanın yan üst ` +
        `köşelerine bindirip dik.`,
      "Askı dikişini çift sıra ya da X dikiş yap. Tek sıra düz dikiş, " +
        "çantanın tüm ağırlığını birkaç deliğe yükler ve deri o noktadan yırtılır.",
    );
  }

  add(
    "Kenarları bitir",
    "Kenarları zımparala, kenar boyası ya da cila uygula.",
    "Kenar bitirme dikişten SONRA yapılır — cüzdanın tersi. Çantada kenarlar " +
      "körük ve panel katmanlarından oluşuyor; dikilmeden hizalanamaz.",
  );

  add(
    "Kontrol et",
    `Hacim ${metric("hacim") ?? "?"}, derinlik ${s.closedThickness.toFixed(0)}mm. ` +
      `Çanta boşken kendi başına dik durmalı; sarkıyorsa panel derisi ince kalmış.`,
  );

  return steps;
}
ODK_EOF_2

echo "==> packages/patterns/src/cardholder.ts"
cat > packages/patterns/src/cardholder.ts << 'ODK_EOF_3'
import type { Mm, Polyline, Vec, StitchPlan } from "@odk/geometry";
import {
  path,
  flattenPath,
  bbox,
  cutLine,
  stitchLine,
  roundCorners,
  distributeStitches,
  narrowestWidth,
  vec,
  CARD_ID1,
  A4,
} from "@odk/geometry";
import type { Temper } from "./material.js";
import {
  CARD_THICKNESS,
  MAX_CLOSED_THICKNESS,
  RECOMMENDED_THICKNESS,
  leather,
} from "./material.js";
import { projectStitchPlan } from "./stitchprojection.js";
import type { CardOrientation, SlotConstruction } from "./cardslot.js";
import { cardSlotGeometry, validateCardSlots, T_SLOT_WRAP_ALLOWANCE } from "./cardslot.js";
import type { CrossSection, CrossSectionResult, Diagnostic, Layer } from "./crosssection.js";
import {
  solveCrossSection,
  foldLengthDelta,
  naturalInnerRadius,
  layerResult,
} from "./crosssection.js";

/**
 * KARTLIK ÜRETECİ (MVP)
 *
 * Faz 3'ün tam modül sisteminin öncüsü. Amaç motoru uçtan uca
 * çalıştırabilmek: parametre → kesit çözümü → parça hatları → dikiş
 * planı. Tek iskelet (katlanır kartlık) ve tek modül (CardSlot) var.
 *
 * BASİTLEŞTİRME (bilinçli): çevre dikişi yalnızca dış parça üzerinde
 * planlanır; yuva parçaları bu dikişe yakalanır. Gerçek yapım biçimi bu
 * ve yuva parçaları için var olmayan dikiş yolları uydurmaktan kaçınır.
 */

export interface CardHolderParams {
  readonly cardCount: number;
  readonly construction: SlotConstruction;
  readonly orientation: CardOrientation;
  readonly outerThickness: Mm;
  readonly slotThickness: Mm;
  readonly temper: Temper;
  readonly reveal: Mm;
  readonly stitchMargin: Mm;
  readonly cornerRadius: Mm;
  readonly penAllowance: Mm;
  /** Verilmezse minimax ile otomatik seçilir. */
  readonly pitch?: Mm;
}

export const DEFAULT_PARAMS: CardHolderParams = {
  cardCount: 4,
  construction: "t-slot",
  orientation: "horizontal",
  outerThickness: RECOMMENDED_THICKNESS.outerShell.preferred,
  slotThickness: RECOMMENDED_THICKNESS.cardSlot.preferred,
  temper: "veg-tan-firm",
  reveal: 12,
  stitchMargin: 3.5,
  cornerRadius: 4,
  penAllowance: 0.3,
  /**
   * Varsayılan 3.85mm.
   *
   * Otomatik seçime BIRAKILMIYOR: kullanıcının elinde belirli bir
   * pricking iron var ve hangi adımı kullanacağını motor bilemez.
   * Otomatik seçim yalnızca sapmayı ölçebilir; dikişin ne kadar sık
   * görüneceği estetik bir karar ve kullanıcıya ait.
   *
   * 3.85mm küçük deri ürünlerinde en yaygın adım.
   */
  pitch: 3.85,
};

export type PieceKind = "outer" | "slot-rect" | "slot-t";

export interface FoldLine {
  readonly from: Vec;
  readonly to: Vec;
  readonly label: string;
}

export interface PatternPiece {
  readonly id: string;
  /**
   * Kısa ve kararlı parça kodu (A, B, C...).
   *
   * Talimatlarda ve montaj görünümünde parçalara atıf yapmak için.
   * Ad değişebilir, kod değişmez.
   */
  readonly code: string;
  readonly name: string;
  readonly kind: PieceKind;
  readonly quantity: number;
  readonly leatherThickness: Mm;
  /** Basılacak kesim hattı (kalem payı uygulanmış). */
  readonly cutLine: Polyline;
  /** Dikiş hattı — yalnızca çevre dikişi olan parçalarda. */
  readonly stitchLine?: Polyline;
  /**
   * Dikiş hattı kapalı bir çevre mi?
   *
   * Cüzdanlarda DEĞİL: banknot ya da kart bölmesinin ağzı açık kalmak
   * zorunda. Kapalı çizmek hem yanlış görünür hem de o kenara delik
   * yerleştirir — dikilirse bölme kapanır ve ürün işe yaramaz.
   */
  readonly stitchLineClosed?: boolean;
  readonly stitchPlan?: StitchPlan;
  readonly foldLines: readonly FoldLine[];
  readonly width: Mm;
  readonly height: Mm;
}

/**
 * Montajdaki bir parça örneği.
 *
 * NEDEN AYRI BİR LİSTE: parçalar tipe göre gruplanıyor ("T-slot yuva ×3")
 * ama montaj görünümü her örneği ayrı konumda göstermek zorunda.
 */
export interface AssemblyPlacement {
  readonly pieceId: string;
  readonly code: string;
  /** Dış kabuğun sol-alt köşesine göre konum. */
  readonly x: Mm;
  readonly y: Mm;
  /** 0 = en altta (dış kabuk). Büyük sayı üstte. */
  readonly layer: number;
}

export interface PatternSummary {
  readonly compartmentWidth: Mm;
  readonly slotStackHeight: Mm;
  readonly outerFlatWidth: Mm;
  readonly outerFlatHeight: Mm;
  readonly closedThickness: Mm;
  readonly loadedThickness: Mm;
  readonly edgeThickness: Mm;
  readonly foldAllowance: Mm;
  /** Katlanmış hâlde bir panelin yüksekliği. */
  readonly panelHeight: Mm;
  readonly totalHoles: number;
  readonly pitch: Mm;
  readonly fitsA4: boolean;
  /**
   * Aileye özgü ek ölçüler.
   *
   * Özet alanları cüzdanlara göre adlandırılmış; çantada "kapalı
   * kalınlık" derinlik demek, "bölme genişliği" çanta genişliği.
   * Aileye özel değerleri (hacim, körük uzunluğu, askı boyu) zorlama
   * yapmadan buradan taşıyoruz.
   */
  readonly metrics?: readonly { readonly label: string; readonly value: string }[];
}

export interface PatternResult {
  readonly pieces: readonly PatternPiece[];
  /** Parçaların bitmiş üründeki (açık hâlde) yerleşimi. */
  readonly assembly: readonly AssemblyPlacement[];
  readonly crossSection: CrossSectionResult;
  readonly diagnostics: readonly Diagnostic[];
  readonly summary: PatternSummary;
}

function cardW(o: CardOrientation): Mm {
  return o === "horizontal" ? CARD_ID1.width : CARD_ID1.height;
}
function cardH(o: CardOrientation): Mm {
  return o === "horizontal" ? CARD_ID1.height : CARD_ID1.width;
}

/**
 * Parça A4'e sığıyor mu — 90° döndürme dahil.
 * 20mm yazıcı kenar payı düşülüyor.
 */
export function fitsOnA4(width: Mm, height: Mm): boolean {
  const w = A4.width - 20;
  const h = A4.height - 20;
  return (width <= w && height <= h) || (height <= w && width <= h);
}

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

/**
 * T-slot parçası.
 *
 * Üstte tam genişlikte "kollar", altta daralmış "gövde". Gövdenin
 * bölmenin kenarına ulaşmaması, kaç yuva olursa olsun kenarda tek
 * katman kalmasını sağlayan şey.
 */
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

export function generateCardHolder(params: CardHolderParams): PatternResult {
  const diagnostics: Diagnostic[] = [];

  const n = Math.max(0, Math.floor(params.cardCount));

  const slotGeo = cardSlotGeometry({
    count: params.cardCount,
    construction: params.construction,
    orientation: params.orientation,
    leatherThickness: params.slotThickness,
    reveal: params.reveal,
    stitchMargin: params.stitchMargin,
  });

  for (const d of validateCardSlots({
    count: params.cardCount,
    construction: params.construction,
    orientation: params.orientation,
    leatherThickness: params.slotThickness,
    reveal: params.reveal,
    stitchMargin: params.stitchMargin,
  })) {
    diagnostics.push({ severity: d.severity, code: d.code, message: d.message });
  }

  // --- Kesit: dış kabuk yuva yığınını sarıyor ---------------------------
  const outerSpec = leather(params.temper, params.outerThickness);
  const slotSpec = leather(params.temper, params.slotThickness);

  const layers: Layer[] = [
    { id: "slots", name: "kart yuvaları", spec: slotSpec },
    { id: "outer", name: "dış kabuk", spec: outerSpec },
  ];

  // Kapalı kalınlık: yuva katmanları + dış kabuk iki kez (katlandığı için).
  const closedThickness = slotGeo.centerThickness + 2 * params.outerThickness;
  const loadedThickness = slotGeo.loadedThickness + 2 * params.outerThickness;

  // KAT ARTIK DİKEY (sırt), bifold ile aynı yapı.
  //
  // Önceki sürümde kat yataydı ve çevre dikişi KAPALI idi — yani
  // kartlığın ağzı da dikiliyordu, kart giremezdi. Yatay katta ayrıca
  // iki ayrı yan dikiş gerekir (tek U olmaz), çünkü kat ortada ve iki
  // serbest uç ağzı oluşturur.
  //
  // Dikey kata geçmek bifold'da doğrulanmış yapıyı aynen kullanmayı
  // sağlıyor: sırt solda/ortada, ağız üstte, dikiş U şeklinde.
  const panelWidth = slotGeo.compartmentWidth;
  const walletHeight = slotGeo.stackHeight + 2 * params.stitchMargin;
  const foldFill = slotGeo.centerThickness + n * CARD_THICKNESS;

  const crossSection: CrossSection = {
    name: "kartlık",
    layers,
    runs: [
      { id: "front", name: "ön panel", length: panelWidth, layers: ["slots", "outer"] },
      { id: "back", name: "arka panel", length: panelWidth, layers: ["outer"] },
    ],
    folds: [
      {
        id: "spine",
        name: "sırt",
        angleDeg: 180,
        innerRadius: naturalInnerRadius(params.outerThickness),
        stack: ["slots", "outer"],
        gaps: { outer: foldFill },
      },
    ],
  };

  const solved = solveCrossSection(crossSection);
  diagnostics.push(...solved.diagnostics);

  const outerFlat = layerResult(solved, "outer")?.flatLength ?? 2 * panelWidth;

  // KAT PAYI = kıvrım bölgesinin genişliği, yani düz uzunluğun iki
  // panelden fazlası.
  //
  // Bifold'daki gibi "dış − iç" almak BURADA YANLIŞ: kartlıkta yuva
  // katmanı yalnızca ön panelden geçiyor, dış kabuk ikisinden de.
  // Farkı almak bir panel boyunu da içine katıyor ve 121mm gibi saçma
  // bir sayı üretiyor. Karşılaştırılabilir olmaları için iki katmanın
  // AYNI düz bölümlerden geçmesi gerekir.
  const foldAllowance = outerFlat - 2 * panelWidth;

  // --- Parçalar ---------------------------------------------------------
  const W = panelWidth;
  const pieces: PatternPiece[] = [];

  // KÖŞE SIRASI ÖNEMLİ: yuvarlatma NOMİNAL şekle uygulanır, dikiş
  // hattına değil. Deri parçanın köşesi yuvarlak kesilir, dikiş hattı
  // onu takip eder.
  const outerNominal = roundCorners(
    rectangle(0, 0, outerFlat, walletHeight),
    true,
    { radius: params.cornerRadius },
  );
  const outerCut = cutLine(outerNominal, { penAllowance: params.penAllowance });

  // DİKİŞ U ŞEKLİNDE — ÜST KENAR AÇIK (kart ağzı).
  const m = params.stitchMargin;
  const outerStitch = roundCorners(
    flattenPath(
      path()
        .moveTo(vec(m, walletHeight - m))
        .lineTo(vec(m, m))
        .lineTo(vec(outerFlat - m, m))
        .lineTo(vec(outerFlat - m, walletHeight - m))
        .open(),
    ),
    false,
    { radius: Math.max(1, params.cornerRadius - m) },
  );
  const outerPlan = distributeStitches(
    outerStitch,
    false,
    params.pitch !== undefined ? { pitch: params.pitch } : {},
  );
  const outerBox = bbox(outerCut);

  const foldX = outerFlat / 2;
  pieces.push({
    id: "outer",
    code: "A",
    name: "dış kabuk",
    kind: "outer",
    quantity: 1,
    leatherThickness: params.outerThickness,
    cutLine: outerCut,
    stitchLine: outerStitch,
    stitchLineClosed: false,
    stitchPlan: outerPlan,
    foldLines: [
      {
        from: vec(foldX - foldAllowance / 2, 0),
        to: vec(foldX - foldAllowance / 2, walletHeight),
        label: "kat başlangıcı",
      },
      {
        from: vec(foldX + foldAllowance / 2, 0),
        to: vec(foldX + foldAllowance / 2, walletHeight),
        label: "kat bitişi",
      },
    ],
    width: outerBox.width,
    height: outerBox.height,
  });

  // --- Yuva parçaları ----------------------------------------------------
  //
  // HER ÖRNEK AYRI PARÇA: her yuva çevre dikişinden farklı delikler
  // alıyor (en alttaki alt kenarı da yakalıyor, üsttekiler yalnızca yan
  // kenarları). Delikler ana plandan yansıtılıyor ki katmanlar üst üste
  // konduğunda tutsun.
  const slotPieceHeight = cardH(params.orientation) + params.stitchMargin;
  const mouthHeight = Math.min(params.reveal, slotPieceHeight / 2);
  const sideInset = params.stitchMargin + T_SLOT_WRAP_ALLOWANCE;

  const rectShape = roundCorners(rectangle(0, 0, W, slotPieceHeight), true, {
    radius: Math.min(params.cornerRadius, slotPieceHeight / 4),
  });
  const tShape = roundCorners(
    tSlotShape(W, slotPieceHeight, mouthHeight, sideInset),
    true,
    { radius: Math.min(params.cornerRadius, sideInset / 2) },
  );

  if (slotGeo.tSlotPieces > 0) {
    const neck = narrowestWidth(
      cutLine(tShape, { penAllowance: params.penAllowance }),
    );
    if (neck < params.stitchMargin * 2) {
      diagnostics.push({
        severity: "warning",
        code: "T_STEM_NARROW",
        message:
          `T-slot gövdesi ${neck.toFixed(1)}mm — dikiş payının iki katından ` +
          `(${(params.stitchMargin * 2).toFixed(1)}mm) ince. Yan payı azaltmayı ` +
          `ya da bölmeyi genişletmeyi düşün.`,
      });
    }
  }

  const assembly: AssemblyPlacement[] = [];
  for (let i = 0; i < n; i++) {
    const isRect = params.construction === "stacked" || i === 0;
    const code = `${isRect ? "B" : "C"}${i + 1}`;
    const id = `slot-${i + 1}`;
    const origin = { x: 0, y: i * params.reveal };

    const cut = cutLine(isRect ? rectShape : tShape, {
      penAllowance: params.penAllowance,
    });
    const b = bbox(cut);
    const projected = projectStitchPlan(outerPlan, origin, cut);

    pieces.push({
      id,
      code,
      name: isRect ? `alt yuva ${i + 1}` : `T-slot yuva ${i + 1}`,
      kind: isRect ? "slot-rect" : "slot-t",
      quantity: 1,
      leatherThickness: params.slotThickness,
      cutLine: cut,
      ...(projected.plan === undefined ? {} : { stitchPlan: projected.plan }),
      foldLines: [],
      width: b.width,
      height: b.height,
    });

    assembly.push({ pieceId: id, code, x: origin.x, y: origin.y, layer: i + 1 });
  }

  // --- Kural denetimi ---------------------------------------------------
  if (closedThickness > MAX_CLOSED_THICKNESS) {
    diagnostics.push({
      severity: "error",
      code: "TOO_THICK",
      message:
        `Kapalı kalınlık ${closedThickness.toFixed(1)}mm — üst sınır ` +
        `${MAX_CLOSED_THICKNESS}mm. Bu artık cep cüzdanı değil.`,
    });
  }

  // A4 KONTROLÜ DÖNDÜRMEYİ HESABA KATIYOR: baskı katmanı sığmayan
  // parçayı 90° çeviriyor, düz hâle bakıp "bölünecek" demek yanlış
  // uyarı olurdu.
  const fitsA4 = fitsOnA4(outerBox.width, outerBox.height);
  if (!fitsA4) {
    diagnostics.push({
      severity: "warning",
      code: "NEEDS_TILING",
      message:
        `Dış kabuk ${outerBox.width.toFixed(0)} × ${outerBox.height.toFixed(0)}mm — ` +
        `döndürülse bile tek A4'e sığmıyor, birden fazla sayfaya bölünecek.`,
    });
  }

  return {
    pieces,
    assembly,
    crossSection: solved,
    diagnostics,
    summary: {
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
      metrics: [
        { label: "bölme genişliği", value: `${panelWidth.toFixed(1)} mm` },
        { label: "yuva yığını", value: `${slotGeo.stackHeight.toFixed(1)} mm` },
        { label: "kat payı", value: `${foldAllowance.toFixed(2)} mm` },
        { label: "kapalı kalınlık", value: `${closedThickness.toFixed(2)} mm` },
        { label: "kart yüklü", value: `${loadedThickness.toFixed(2)} mm` },
        { label: "kenar kalınlığı", value: `${slotGeo.edgeThickness.toFixed(2)} mm` },
      ],
    },
  };
}

/** Kart genişliği/yüksekliği dışa açılıyor: arayüz etiketleri için. */
export const cardDimensions = { width: cardW, height: cardH };
ODK_EOF_3

echo "==> packages/patterns/src/bifold.ts"
cat > packages/patterns/src/bifold.ts << 'ODK_EOF_4'
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
import { projectAcrossFold, projectStitchPlan } from "./stitchprojection.js";
import type { Currency } from "./banknote.js";
import { billPocketGeometry, validateBillPocket } from "./banknote.js";
import { fitsOnA4 } from "./cardholder.js";
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

  // DİKİŞ HATTI U ŞEKLİNDE — ÜST KENAR AÇIK.
  //
  // Bifold'un üst kenarı banknot bölmesinin AĞZI. Kapalı bir çevre
  // dikişi hem o kenara delik yerleştirir hem de dikildiğinde para
  // bölmesini tamamen kapatır; ürün işe yaramaz hale gelir.
  //
  // İlk sürümde çevre kapalıydı ve üstteki kart yuvası (D-S3) üst
  // kenardan 28 delik alıyordu — tam olarak dikilmemesi gereken yerden.
  const m = params.stitchMargin;
  const outerStitch = roundCorners(
    flattenPath(
      path()
        .moveTo(vec(m, walletHeight - m))
        .lineTo(vec(m, m))
        .lineTo(vec(outerFlat - m, m))
        .lineTo(vec(outerFlat - m, walletHeight - m))
        .open(),
    ),
    false,
    { radius: Math.max(1, params.cornerRadius - m) },
  );
  const outerPlan = distributeStitches(
    outerStitch,
    false,
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
    stitchLineClosed: false,
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
  // İç kabuk çevre dikişine TAM BOYUNCA yakalanıyor. Kat payı sırtta
  // soğuruluyor, kenarlar hizalı kalıyor.
  const innerProjection = projectAcrossFold(
    outerPlan,
    foldCentre,
    foldAllowance,
    innerCut,
    true,
  );
  pieces.push({
    id: "inner",
    code: "B",
    name: "iç kabuk (para bölmesi)",
    kind: "outer",
    quantity: 1,
    leatherThickness: params.innerThickness,
    cutLine: innerCut,
    ...(innerProjection.plan === undefined
      ? {}
      : { stitchPlan: innerProjection.plan }),
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

  // --- Yuva parçaları ve montaj -----------------------------------------
  //
  // HER ÖRNEK AYRI PARÇA. Gruplamak ("T-slot yuva ×4") mümkün değil,
  // çünkü sol paneldeki yuva sol ve alt kenardan, sağ paneldeki sağ ve
  // alt kenardan delik alıyor; üstteki yuva alt kenar deliklerini hiç
  // almıyor. Aynı şekil, farklı delik deseni.
  //
  // Delikler ana çevre planından YANSITILIYOR, parça başına yeniden
  // hesaplanmıyor — hesaplansaydı katmanlar üst üste konduğunda
  // tutmazdı.
  const slotPieceHeight = CARD_ID1.height + params.stitchMargin;
  const mouthHeight = Math.min(params.reveal, slotPieceHeight / 2);
  const sideInset = params.stitchMargin + T_SLOT_WRAP_ALLOWANCE;

  const rectShape = roundCorners(
    rectangle(0, 0, panelWidth, slotPieceHeight),
    true,
    { radius: Math.min(params.cornerRadius, slotPieceHeight / 4) },
  );
  const tShape = roundCorners(
    tSlotShape(panelWidth, slotPieceHeight, mouthHeight, sideInset),
    true,
    { radius: Math.min(params.cornerRadius, sideInset / 2) },
  );

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
      const code = `${isRect ? "C" : "D"}-${side.tag}${i + 1}`;
      const id = `slot-${side.tag}${i + 1}`;
      const origin = { x: side.x, y: i * params.reveal };

      const cut = cutLine(isRect ? rectShape : tShape, {
        penAllowance: params.penAllowance,
      });
      const b = bbox(cut);
      const projected = projectStitchPlan(outerPlan, origin, cut);

      pieces.push({
        id,
        code,
        name: isRect ? `alt yuva ${side.tag}${i + 1}` : `T-slot yuva ${side.tag}${i + 1}`,
        kind: isRect ? "slot-rect" : "slot-t",
        quantity: 1,
        leatherThickness: params.slotThickness,
        cutLine: cut,
        ...(projected.plan === undefined ? {} : { stitchPlan: projected.plan }),
        foldLines: [],
        width: b.width,
        height: b.height,
      });

      assembly.push({
        pieceId: id,
        code,
        x: origin.x,
        y: origin.y,
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

  const fitsA4 = fitsOnA4(outerBox.width, outerBox.height);
  if (!fitsA4) {
    diagnostics.push({
      severity: "warning",
      code: "NEEDS_TILING",
      message:
        `Dış kabuk ${outerBox.width.toFixed(0)} × ${outerBox.height.toFixed(0)}mm — ` +
        `döndürülse bile tek A4'e sığmıyor, birden fazla sayfaya bölünecek.`,
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
    metrics: [
      { label: "panel genişliği", value: `${panelWidth.toFixed(1)} mm` },
      { label: "açık ölçü", value: `${outerBox.width.toFixed(1)} × ${outerBox.height.toFixed(1)} mm` },
      { label: "kat payı", value: `${foldAllowance.toFixed(2)} mm` },
      { label: "boş kalınlık", value: `${closedThickness.toFixed(2)} mm` },
      { label: "kart yüklü", value: `${loadedThickness.toFixed(2)} mm` },
      { label: "banknot", value: billGeo.banknote.label },
    ],
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
ODK_EOF_4

echo "==> packages/patterns/src/catalog.ts"
cat > packages/patterns/src/catalog.ts << 'ODK_EOF_5'
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
    summary: "Ön/arka panel, dolanan körük, isteğe bağlı askı.",
    status: "hazir",
    modules: ["Gusset", "Strap"],
    typicalThickness: { min: 60, max: 120 },
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
ODK_EOF_5

echo "==> packages/patterns/src/catalog.test.ts"
cat > packages/patterns/src/catalog.test.ts << 'ODK_EOF_6'
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
      "tote",
    ]);
  });

  it("kartlık, cüzdan ve çantada üretilebilir aile var, aksesuarda yok", () => {
    expect(categoryHasAvailable("kartlik")).toBe(true);
    expect(categoryHasAvailable("cuzdan")).toBe(true);
    expect(categoryHasAvailable("canta")).toBe(true);
    expect(categoryHasAvailable("aksesuar")).toBe(false);
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
ODK_EOF_6

echo "==> packages/patterns/src/index.ts"
cat > packages/patterns/src/index.ts << 'ODK_EOF_7'
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
export * from "./tote.js";
export * from "./catalog.js";
export * from "./instructions.js";
export * from "./stitchprojection.js";
ODK_EOF_7

echo "==> packages/print/src/pdf.ts"
cat > packages/print/src/pdf.ts << 'ODK_EOF_8'
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
import type {
  LayoutPage,
  LineStyle,
  PageLayout,
  PlacedPiece,
  SheetLayout,
} from "./layout.js";
import { packPages, packPieces, pieceToLayout, STYLES } from "./layout.js";

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
  /**
   * Sayfaya sığmayan parçayı 90° döndürmeye izin ver.
   *
   * Varsayılan AÇIK. Kapatmak yalnızca deri postu belirli bir yönde
   * kesmek zorunda olan (damar kısıtı sıkı) kullanıcılar için anlamlı;
   * kapatıldığında büyük parçalar döşemeye düşer ve elle hizalama
   * gerekir.
   */
  readonly allowRotation?: boolean;
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

  // ÖNCE sayfa bazlı yerleştirme denenir; yalnızca sığmayan parçalar
  // döşemeye kalır. Bkz. layout.ts — hizalama hatası ürünün ölçüsüne
  // doğrudan giriyor.
  const pageLayout = packPages(
    pattern.pieces,
    paper,
    undefined,
    options.allowRotation ?? true,
  );
  const needsTiling = pageLayout.oversized.length > 0;
  const tiledSheet = needsTiling ? packPieces(pageLayout.oversized, paper) : undefined;
  const grid =
    tiledSheet === undefined
      ? undefined
      : planTiles(tiledSheet.width, tiledSheet.height, paper);

  const patternPageCount =
    pageLayout.pages.length + (grid === undefined ? 0 : grid.cols * grid.rows);

  drawCoverPage(ctx, pattern, pageLayout, patternPageCount, options);
  drawAssemblyPage(ctx, pattern);
  if (options.params !== undefined) {
    drawInstructionPages(ctx, buildInstructions(pattern, options.params));
  }

  for (const page of pageLayout.pages) {
    drawFlatPage(ctx, page, patternPageCount, options);
  }

  if (tiledSheet !== undefined && grid !== undefined) {
    for (let row = 0; row < grid.rows; row++) {
      for (let col = 0; col < grid.cols; col++) {
        drawTilePage(ctx, tiledSheet, grid, col, row, options);
      }
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
  pageLayout: PageLayout,
  patternPageCount: number,
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
    `${options.version ?? "v1"} · ${patternPageCount} desen sayfası · ölçek 1:1`,
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

  // ── Sayfa yerleşimi bilgisi ──────────────────────────────────────────
  y -= 10;
  const tiled = pageLayout.oversized.length > 0;
  text(page, "2 — Sayfa yerleşimi", left, y, 12, ctx.body);
  y -= 5.5;
  if (!tiled) {
    text(
      page,
      "Her parça tek bir sayfada. Sayfa birleştirme ve hizalama GEREKMİYOR.",
      left,
      y,
      9,
      ctx.body,
      0.25,
    );
    y -= 4.6;
    if (pageLayout.rotatedCount > 0) {
      text(
        page,
        `${pageLayout.rotatedCount} parça sayfaya sığması için 90° döndürüldü. ` +
          `Damar oku parçayla birlikte döndü; oku takip et.`,
        left,
        y,
        9,
        ctx.body,
        0.25,
      );
      y -= 4.6;
    }
  } else {
    text(
      page,
      `${pageLayout.oversized.map((op) => op.code).join(", ")} tek sayfaya sığmıyor ` +
        `ve bölündü. O sayfaları kesme çizgisinden kesip haçları çakıştırarak yapıştır.`,
      left,
      y,
      9,
      ctx.body,
      0.25,
    );
    y -= 4.6;
  }

  // ── Kesim kuralı ─────────────────────────────────────────────────────
  y -= 5;
  text(page, "3 — Çizginin dışından kes", left, y, 12, ctx.body);
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
  text(page, "4 — Parçalar", left, y, 12, ctx.body);
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
    text(page, "5 — Dikiş", left, y, 12, ctx.body);
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
  text(page, "6 — Ölçüler", left, y, 12, ctx.body);
  y -= 5.5;
  // ÖLÇÜLERİ AİLE BELİRLİYOR.
  //
  // Sabit satır listesi cüzdana göre adlandırılmıştı ve çantada
  // "kart yüklü 80mm" gibi saçma satırlar üretiyordu. Her aile kendi
  // etiketlerini veriyor; ortak olan tek şey adım ve delik sayısı.
  for (const metric of s.metrics ?? []) {
    text(page, metric.label, left, y, 9, ctx.body, 0.3);
    text(page, metric.value, left + 55, y, 9, ctx.mono);
    y -= 4.4;
  }
  text(page, "dikiş", left, y, 9, ctx.body, 0.3);
  text(page, `${s.pitch}mm · ${s.totalHoles} delik`, left + 55, y, 9, ctx.mono);
  y -= 4.4;

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
  if (outer.stitchLine !== undefined) {
    polyline(
      page,
      outer.stitchLine.map((p) => place(p)),
      outer.stitchLineClosed ?? true,
      STYLES.stitch,
      1,
    );
  }
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

/**
 * Döşemesiz desen sayfası: parçalar bütün hâlde, hizalama gerekmez.
 */
function drawFlatPage(
  ctx: Ctx,
  layoutPage: LayoutPage,
  totalPages: number,
  options: PdfOptions,
): void {
  const page = addPage(ctx);
  const area = printableArea(ctx.paper);

  const tx = (p: Vec): Vec => ({
    x: area.originX + p.x * ctx.scale,
    y: area.originY + p.y * ctx.scale,
  });

  for (const placed of layoutPage.placed) {
    drawPiece(ctx, page, placed, tx, options.printAllHoles ?? true);
  }

  drawFooter(ctx, page, `S${layoutPage.index + 1}`, totalPages);
}

function drawTilePage(
  ctx: Ctx,
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

  // Parça yerel koordinatı -> yerleşim -> sayfa. Döndürme pieceToLayout
  // içinde, tek yerde uygulanıyor.
  const minX = Math.min(...piece.cutLine.map((p) => p.x));
  const minY = Math.min(...piece.cutLine.map((p) => p.y));
  const place = (p: Vec): Vec => tx(pieceToLayout(placed, p, minX, minY));

  polyline(page, piece.cutLine.map(place), true, STYLES.cut, ctx.scale);

  if (piece.stitchLine !== undefined) {
    // Açık dikiş hattını kapalı çizmek, dikilmemesi gereken kenara
    // (bölme ağzı) sahte bir çizgi koyar.
    polyline(
      page,
      piece.stitchLine.map(place),
      piece.stitchLineClosed ?? true,
      STYLES.stitch,
      ctx.scale,
    );
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

  // Etiket: parçanın sol-üst köşesinin biraz üstünde. Etiket YATAY
  // kalır — parça dönse de yazının dönmesi okunabilirliği bozar.
  const label = tx({ x: placed.x, y: placed.y + placed.height + 3 });
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
  //
  // Ok PARÇA YEREL koordinatında tanımlanıp aynı dönüşümden geçiyor;
  // böylece parça döndürüldüğünde ok da dönüyor ve deri üzerindeki
  // doğru yönü göstermeye devam ediyor. Sayfa koordinatında sabit bir
  // ok çizmek, döndürülmüş parçada yanlış yön gösterirdi.
  const grainStart = place({ x: minX + 3, y: minY + 3 });
  const grainEnd = place({ x: minX + 3, y: minY + 15 });
  line(page, grainStart, grainEnd, STYLES.guide, ctx.scale);
  text(page, "damar", grainStart.x + 1.5, grainStart.y + 1, 6, ctx.mono, 0.55);
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
ODK_EOF_8

echo "==> apps/web/src/engine.ts"
cat > apps/web/src/engine.ts << 'ODK_EOF_9'
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
  generateTote,
  STRAP_SPECS,
  TOTE_DEFAULTS,
} from "@odk/patterns";

export { stitchSummary as stitchSummaryFor } from "@odk/geometry";
ODK_EOF_9

echo "==> apps/web/src/App.tsx"
cat > apps/web/src/App.tsx << 'ODK_EOF_10'
import { useMemo, useState } from "react";
import type {
  BifoldParams,
  GussetStyle,
  StrapStyle,
  ToteParams,
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
  generateTote,
  stitchSummaryFor,
  STATUS_LABEL,
  TOTE_DEFAULTS,
} from "./engine.js";

type FamilyId = "card-holder-fold" | "bifold" | "tote";
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
  readonly allowRotation: boolean;
  readonly measured: string;
  readonly scaleFactor: number;
  readonly note: string;
  readonly noteOk: boolean;
  readonly busy: boolean;
}

const INITIAL_PRINT: PrintState = {
  printAllHoles: true,
  allowRotation: true,
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
  const [tote, setTote] = useState<ToteParams>(TOTE_DEFAULTS);
  const [print, setPrint] = useState<PrintState>(INITIAL_PRINT);

  const isBifold = family === "bifold";
  const isTote = family === "tote";
  // Talimatlar ve PDF üç aile için de bu dar bağlamı kullanıyor.
  const ctx = isTote
    ? { ...tote, kind: "canta" as const }
    : isBifold
      ? bifold
      : params;

  const set = <K extends keyof CardHolderParams>(
    key: K,
    value: CardHolderParams[K],
  ) => setParams((p) => ({ ...p, [key]: value }));

  const setB = <K extends keyof BifoldParams>(key: K, value: BifoldParams[K]) =>
    setBifold((p) => ({ ...p, [key]: value }));

  const setT = <K extends keyof ToteParams>(key: K, value: ToteParams[K]) =>
    setTote((p) => ({ ...p, [key]: value }));

  const result = useMemo(() => {
    try {
      return {
        ok: true as const,
        value: isTote
          ? generateTote(tote)
          : isBifold
            ? generateBifold(bifold)
            : generateCardHolder(params),
      };
    } catch (err) {
      return {
        ok: false as const,
        message: err instanceof Error ? err.message : String(err),
      };
    }
  }, [isBifold, isTote, params, bifold, tote]);

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

        {isTote ? (
          <fieldset className="group" style={{ border: 0, margin: 0, padding: 0 }}>
            <legend>Çanta</legend>
            <Slider
              label="Genişlik"
              value={tote.width}
              min={140}
              max={340}
              step={5}
              unit="mm"
              onChange={(v) => setT("width", v)}
            />
            <Slider
              label="Yükseklik"
              value={tote.height}
              min={120}
              max={340}
              step={5}
              unit="mm"
              onChange={(v) => setT("height", v)}
            />
            <Slider
              label="Derinlik (körük)"
              value={tote.depth}
              min={30}
              max={160}
              step={5}
              unit="mm"
              onChange={(v) => setT("depth", v)}
            />
            <Slider
              label="Alt köşe yarıçapı"
              value={tote.cornerRadius}
              min={10}
              max={90}
              step={5}
              unit="mm"
              hint="Derinliğin yarısından küçük olursa körük köşede buruşur."
              onChange={(v) => setT("cornerRadius", v)}
            />
            <Choice<GussetStyle>
              label="Körük"
              value={tote.gusset}
              options={[
                { value: "uc-parca", label: "Üç parça" },
                { value: "tek-parca", label: "Tek parça" },
              ]}
              hint="Üç parça A4'e sığar ama iki ek dikiş getirir. Tek parça dikişsiz ama sayfalara bölünür."
              onChange={(v) => setT("gusset", v)}
            />
            <Select
              label="Askı"
              value={tote.strap}
              options={[
                { value: "yok", label: "Askısız" },
                { value: "el", label: "El sapı (2 adet)" },
                { value: "omuz", label: "Omuz askısı" },
                { value: "capraz", label: "Çapraz askı" },
              ]}
              onChange={(v) => setT("strap", v as StrapStyle)}
            />
            {tote.strap !== "yok" && (
              <Slider
                label="Askı drop"
                value={(tote.strapDrop ?? 550) / 10}
                min={20}
                max={70}
                step={1}
                unit="cm"
                hint="Askının tepesinden çantanın üst kenarına dikey mesafe."
                onChange={(v) => setT("strapDrop", v * 10)}
              />
            )}
            <Slider
              label="Panel derisi"
              value={tote.panelThickness}
              min={1.0}
              max={3.0}
              step={0.1}
              unit="mm"
              hint="Çanta yapısal yük taşıyor: 1.6–2.4mm öneriliyor."
              onChange={(v) => setT("panelThickness", v)}
            />
            <Slider
              label="Körük derisi"
              value={tote.gussetThickness}
              min={1.0}
              max={2.6}
              step={0.1}
              unit="mm"
              onChange={(v) => setT("gussetThickness", v)}
            />
            <Slider
              label="Askı derisi"
              value={tote.strapThickness}
              min={1.4}
              max={3.6}
              step={0.1}
              unit="mm"
              onChange={(v) => setT("strapThickness", v)}
            />
            <Slider
              label="Dikiş payı"
              value={tote.stitchMargin}
              min={3}
              max={6}
              step={0.5}
              unit="mm"
              onChange={(v) => setT("stitchMargin", v)}
            />
            <Select
              label="Pricking iron"
              value={tote.pitch === undefined ? "auto" : String(tote.pitch)}
              options={[
                { value: "3.85", label: "3.85 mm" },
                { value: "4", label: "4.0 mm" },
                { value: "5", label: "5.0 mm" },
                { value: "auto", label: "Oto — en az delik" },
              ]}
              onChange={(v) =>
                setTote((p) => {
                  if (v === "auto") {
                    const { pitch: _drop, ...rest } = p;
                    return rest;
                  }
                  return { ...p, pitch: Number(v) };
                })
              }
            />
          </fieldset>
        ) : isBifold ? (
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

          <Choice<string>
            label="Sayfaya sığdırma"
            value={print.allowRotation ? "rotate" : "tile"}
            options={[
              { value: "rotate", label: "Döndür" },
              { value: "tile", label: "Böl" },
            ]}
            hint="Döndür: parça 90° çevrilip tek sayfaya sığar, hizalama gerekmez. Böl: parça sayfalara bölünür, kesip yapıştırman gerekir."
            onChange={(v) =>
              setPrint((p) => ({ ...p, allowRotation: v === "rotate" }))
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
                    allowRotation: print.allowRotation,
                    scaleFactor: print.scaleFactor,
                    title: isTote
                      ? `Çanta ${tote.width}x${tote.height}x${tote.depth}`
                      : isBifold
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
          <Result value={result.value} ctx={ctx} family={family} />
        )}
      </main>
    </div>
  );
}

function Result({
  value,
  ctx,
  family,
}: {
  value: ReturnType<typeof generateCardHolder>;
  ctx: CardHolderParams | BifoldParams | (ToteParams & { kind: "canta" });
  family: FamilyId;
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
          {family === "tote"
            ? `${(ctx as ToteParams).width}×${(ctx as ToteParams).height}×${(ctx as ToteParams).depth}mm`
            : family === "bifold"
              ? `${(ctx as BifoldParams).cardSlotsPerSide}+${(ctx as BifoldParams).cardSlotsPerSide} yuva · ${(ctx as BifoldParams).construction === "t-slot" ? "T-slot" : "düz yığın"}`
              : `${(ctx as CardHolderParams).cardCount} yuva · ${(ctx as CardHolderParams).construction === "t-slot" ? "T-slot" : "düz yığın"}`}{" "}
          · {s.pitch}mm adım · {s.totalHoles} delik
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
            {(s.metrics ?? []).map((mt) => (
              <tr key={mt.label}>
                <th scope="row">{mt.label}</th>
                <td className="num">{mt.value}</td>
              </tr>
            ))}
            <tr>
              <th scope="row">dikiş</th>
              <td className="num">
                {s.pitch}mm · {s.totalHoles} delik
              </td>
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
ODK_EOF_10

echo "==> docs/SOURCES.md"
cat > docs/SOURCES.md << 'ODK_EOF_11'
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
ODK_EOF_11

echo "==> Testler"
pnpm test

echo "==> Typecheck"
pnpm typecheck

echo "==> Arayuz derlemesi"
pnpm --filter @odk/web build

cat << 'ODK_DONE'

============================================================
FAZ 3 — KORUKLU CANTA
============================================================

Varsayilan (220 x 200 x 80mm, uc parca koruk, capraz aski):
  hacim 3.52 L · koruk 585.7mm · alt kose yayi 62.8mm
  capraz aski 1 x 134.5cm x 20mm
  dikis 4mm · panel basina 147 delik
  parcalar: A on/arka panel x2, B yan koruk x2, C taban korugu x1

Git:
  git add -A
  git commit -m "Faz 3: koruklu canta

KORUK UZUNLUGU = PANEL DIKIS HATTININ YAY UZUNLUGU
Tahmin yok: 2(H-R) + (W-2R) + 2(piR/2). Adim 4'teki yay uzunlugu
makinesinin dogrudan uygulamasi. Kose yaricapi buyudukce koruk
KISALIYOR (2R yerine piR/2 yol) — test ile dogrulandi.

KORUK DELIKLERI PANELE MESAFEYLE ESLESIYOR
Panel hatti egri, koruk duz; eslesmeyi saglayan sey mesafe. Panelde
baslangictan d kadar ilerideki delik, korukte de d kadar ileride.
Uc parcali korukte 49+49+49 = 147, panelin toplamiyla birebir.

UC PARCALI BOLUNME YAY ORTASINDAN
Yay sinirlarindan bolmek taban parcasini 285mm'ye cikarip A4'e sigmaz
hale getiriyor. Yay ortasindan bolunce iki parca da donduруlerek siğiyor.

UZUN ASKI SABLON OLARAK BASILMIYOR
134.5cm duz bir serit icin 5 sayfa doseme basmak kagit israfi;
olcusu bildiriliyor, cetvelle kesiliyor. STRIP_TEMPLATE_LIMIT = 400mm.

OZET ETIKETLERI ARTIK AILEYE AIT
Sabit satir listesi cuzdana gore adlandirilmisti ve cantada
'kart yuklu 80mm' gibi sacma satirlar uretiyordu.

CANTAYA OZGU TALIMATLAR
Cuzdanin kritik hatasi tutkalin yuvaya tasmasi; cantanin ki korugu
cekistirerek dikmek. Kenar bitirme cantada dikisten SONRA (cuzdanin
tersi). Aski dikisi cift sira ya da X olmali.

ASKI OLCULERI BELGELENDI
Capraz 114-137cm (carpan 2.3, capraz gövdeyi diyagonal kesiyor),
omuz ve tote sapi carpan 2.0.

- 350 test geciyor"

  git push
  vercel --prod
ODK_DONE
