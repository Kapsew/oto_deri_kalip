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
