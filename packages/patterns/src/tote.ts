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
