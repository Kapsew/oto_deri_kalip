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
  /** Bir dikiş hattındaki delik sayısı (ana plan). */
  readonly totalHoles: number;
  /**
   * Gerçekten DİKİLECEK delik sayısı.
   *
   * totalHoles'tan farklı olabilir: çantada iki ayrı dikiş var
   * (ön panel–körük ve arka panel–körük), cüzdanda tek çevre dikişi.
   *
   * Parça başına delikleri toplamak YANLIŞ olur — dikiş bütün
   * katmanlardan bir kerede geçiyor, aynı fiziksel delik her katmanda
   * ayrı sayılmamalı.
   */
  readonly stitchedHoles: number;
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
      stitchedHoles: outerPlan.totalHoles,
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
