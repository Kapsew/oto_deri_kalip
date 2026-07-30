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
import { leather, RECOMMENDED_THICKNESS, MAX_CLOSED_THICKNESS } from "./material.js";
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
};

export type PieceKind = "outer" | "slot-rect" | "slot-t";

export interface FoldLine {
  readonly from: Vec;
  readonly to: Vec;
  readonly label: string;
}

export interface PatternPiece {
  readonly id: string;
  readonly name: string;
  readonly kind: PieceKind;
  readonly quantity: number;
  readonly leatherThickness: Mm;
  /** Basılacak kesim hattı (kalem payı uygulanmış). */
  readonly cutLine: Polyline;
  /** Dikiş hattı — yalnızca çevre dikişi olan parçalarda. */
  readonly stitchLine?: Polyline;
  readonly stitchPlan?: StitchPlan;
  readonly foldLines: readonly FoldLine[];
  readonly width: Mm;
  readonly height: Mm;
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
  readonly totalHoles: number;
  readonly pitch: Mm;
  readonly fitsA4: boolean;
}

export interface PatternResult {
  readonly pieces: readonly PatternPiece[];
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

  const panelHeight = slotGeo.stackHeight + params.stitchMargin;
  const innerRadius = naturalInnerRadius(slotGeo.centerThickness);

  const crossSection: CrossSection = {
    name: "kartlık",
    layers,
    runs: [
      { id: "front", name: "ön panel", length: panelHeight, layers: ["slots", "outer"] },
      { id: "back", name: "arka panel", length: panelHeight, layers: ["outer"] },
    ],
    folds: [
      {
        id: "spine",
        name: "kat",
        angleDeg: 180,
        innerRadius,
        stack: ["slots", "outer"],
      },
    ],
  };

  const solved = solveCrossSection(crossSection);
  diagnostics.push(...solved.diagnostics);

  const foldAllowance = foldLengthDelta(
    slotGeo.centerThickness + params.outerThickness,
    180,
  );

  // --- Parçalar ---------------------------------------------------------
  const W = slotGeo.compartmentWidth;
  const outerFlat = layerResult(solved, "outer")?.flatLength ?? 2 * panelHeight;

  const pieces: PatternPiece[] = [];

  // Dış kabuk: katlanan tek parça, çevre dikişi burada.
  //
  // KÖŞE SIRASI ÖNEMLİ: yuvarlatma NOMİNAL şekle uygulanır, dikiş
  // hattına değil. Fiziksel gerçek bu — deri parçanın köşesi yuvarlak
  // kesilir, dikiş hattı da onu takip eder. Yalnızca dikiş hattını
  // yuvarlatmak, keskin köşeli bir parçaya yuvarlak dikiş çizmek olurdu.
  const outerNominal = roundCorners(rectangle(0, 0, W, outerFlat), true, {
    radius: params.cornerRadius,
  });
  const outerCut = cutLine(outerNominal, { penAllowance: params.penAllowance });
  const outerStitchRaw = stitchLine(outerCut, params.stitchMargin);
  // İçe öteleme yuvarlatmayı küçültür ve yarıçap dikiş payından küçükse
  // köşeyi tekrar keskinleştirir (Adım 5 bulgusu). İkinci geçiş bunu
  // telafi eder; zaten yumuşak olan noktalara dokunmaz.
  const outerStitch = roundCorners(outerStitchRaw, true, {
    radius: Math.max(1, params.cornerRadius - params.stitchMargin),
  });
  const outerPlan = distributeStitches(
    outerStitch,
    true,
    params.pitch !== undefined ? { pitch: params.pitch } : {},
  );
  const outerBox = bbox(outerCut);

  // Kat çizgisi: nötr eksen boyunca hesaplanan uzunluğun ortası.
  const foldY = outerFlat / 2;
  pieces.push({
    id: "outer",
    name: "dış kabuk",
    kind: "outer",
    quantity: 1,
    leatherThickness: params.outerThickness,
    cutLine: outerCut,
    stitchLine: outerStitch,
    stitchPlan: outerPlan,
    foldLines: [
      {
        from: vec(0, foldY - foldAllowance / 2),
        to: vec(W, foldY - foldAllowance / 2),
        label: "kat başlangıcı",
      },
      {
        from: vec(0, foldY + foldAllowance / 2),
        to: vec(W, foldY + foldAllowance / 2),
        label: "kat bitişi",
      },
    ],
    width: outerBox.width,
    height: outerBox.height,
  });

  // Yuva parçaları.
  const slotPieceHeight = cardH(params.orientation) + params.stitchMargin;
  const mouthHeight = Math.min(params.reveal, slotPieceHeight / 2);
  const sideInset = params.stitchMargin + T_SLOT_WRAP_ALLOWANCE;

  if (slotGeo.rectanglePieces > 0) {
    const nominal = roundCorners(rectangle(0, 0, W, slotPieceHeight), true, {
      radius: Math.min(params.cornerRadius, slotPieceHeight / 4),
    });
    const cut = cutLine(nominal, { penAllowance: params.penAllowance });
    const b = bbox(cut);
    pieces.push({
      id: "slot-rect",
      name: "alt yuva (düz)",
      kind: "slot-rect",
      quantity: slotGeo.rectanglePieces,
      leatherThickness: params.slotThickness,
      cutLine: cut,
      foldLines: [],
      width: b.width,
      height: b.height,
    });
  }

  if (slotGeo.tSlotPieces > 0) {
    const nominal = roundCorners(
      tSlotShape(W, slotPieceHeight, mouthHeight, sideInset),
      true,
      { radius: Math.min(params.cornerRadius, sideInset / 2) },
    );
    const cut = cutLine(nominal, { penAllowance: params.penAllowance });
    const b = bbox(cut);

    // Gövde, dikiş hattının içine girmemeli.
    const neck = narrowestWidth(cut);
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

    pieces.push({
      id: "slot-t",
      name: "T-slot yuva",
      kind: "slot-t",
      quantity: slotGeo.tSlotPieces,
      leatherThickness: params.slotThickness,
      cutLine: cut,
      foldLines: [],
      width: b.width,
      height: b.height,
    });
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

  const fitsA4 = outerBox.width <= A4.width - 20 && outerBox.height <= A4.height - 20;
  if (!fitsA4) {
    diagnostics.push({
      severity: "warning",
      code: "NEEDS_TILING",
      message:
        `Dış kabuk ${outerBox.width.toFixed(0)} × ${outerBox.height.toFixed(0)}mm — ` +
        `tek A4'e kenar payıyla sığmıyor, birden fazla sayfaya bölünecek.`,
    });
  }

  return {
    pieces,
    crossSection: solved,
    diagnostics,
    summary: {
      compartmentWidth: W,
      slotStackHeight: slotGeo.stackHeight,
      outerFlatWidth: outerBox.width,
      outerFlatHeight: outerBox.height,
      closedThickness,
      loadedThickness,
      edgeThickness: slotGeo.edgeThickness,
      foldAllowance,
      totalHoles: outerPlan.totalHoles,
      pitch: outerPlan.pitch,
      fitsA4,
    },
  };
}

/** Kart genişliği/yüksekliği dışa açılıyor: arayüz etiketleri için. */
export const cardDimensions = { width: cardW, height: cardH };
