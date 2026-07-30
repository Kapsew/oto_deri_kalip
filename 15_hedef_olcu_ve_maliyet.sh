#!/usr/bin/env bash
#
# 15_hedef_olcu_ve_maliyet.sh
#
# 1) Bifold'da HEDEF KAPALI OLCU modu (ornek: 95 x 75mm)
# 2) Maliyet ve onerilen fiyat hesabi
#
# Repo kokunde calistir. Idempotent.

set -euo pipefail

if [ ! -f "pnpm-workspace.yaml" ] || [ ! -d "packages/print" ]; then
  echo "HATA: Repo kokunde calistirilmali ve 14 uygulanmis olmali." >&2
  exit 1
fi

echo "==> packages/patterns/src/bifold.ts"
cat > packages/patterns/src/bifold.ts << 'ODK_EOF_0'
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
  /**
   * HEDEF KAPALI ÖLÇÜ.
   *
   * Verilmezse ölçüler kısıtlardan türetilir (kart + banknot + paylar).
   * Verilirse ölçü SABİTLENİR ve motor kısıtların sağlanıp sağlanmadığını
   * raporlar. İkinci mod, "kapalı hâli 95 × 75mm olsun" gibi somut bir
   * hedefle çalışırken gerekli — o hedefin fiziksel olarak mümkün olup
   * olmadığını söylemek motorun işi.
   */
  readonly targetClosedWidth?: Mm;
  readonly targetClosedHeight?: Mm;
}

/**
 * Kartın yuvaya girip çıkabilmesi için gereken mutlak asgari boşluk.
 *
 * Belgelenmiş rahat değer 7.4mm (100mm bölme genişliğinden türetilmişti).
 * 2mm altında kart sürtünmeden giremiyor ve deri kenarı zorlanıyor.
 */
export const MIN_CARD_CLEARANCE: Mm = 2;

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
  const targeted =
    params.targetClosedWidth !== undefined || params.targetClosedHeight !== undefined;

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

  const derivedPanelWidth = slotGeo.compartmentWidth;
  const widthFromCards = 2 * derivedPanelWidth;
  const widthFromBill = billGeo.compartmentWidth;

  const heightFromCards = slotGeo.stackHeight + 2 * params.stitchMargin;
  const derivedHeight = Math.max(heightFromCards, billGeo.minWalletHeight);

  const panelWidth = params.targetClosedWidth ?? derivedPanelWidth;
  const walletHeight = params.targetClosedHeight ?? derivedHeight;

  if (targeted) {
    // HEDEF MODDA KISITLARI RAPORLA.
    //
    // Ölçüyü sabitlemek kısıtları ortadan kaldırmıyor; yalnızca hangi
    // kısıtın ne kadar zorlandığını görünür kılıyor. Sessizce ölçüyü
    // değiştirmek de, kısıtı yok saymak da kullanıcıyı yanıltırdı.
    const cardW = CARD_ID1.width;
    const clearance = panelWidth - cardW - 2 * params.stitchMargin;
    if (clearance < 0) {
      diagnostics.push({
        severity: "error",
        code: "TARGET_TOO_NARROW",
        message:
          `Kapalı genişlik ${panelWidth}mm — kart ${cardW}mm ve iki yanda ` +
          `${params.stitchMargin}mm dikiş payı toplam ` +
          `${(cardW + 2 * params.stitchMargin).toFixed(1)}mm ediyor. Kart sığmıyor. ` +
          `Dikiş payını düşür ya da genişliği en az ` +
          `${(cardW + 2 * params.stitchMargin + MIN_CARD_CLEARANCE).toFixed(1)}mm yap.`,
      });
    } else if (clearance < MIN_CARD_CLEARANCE) {
      diagnostics.push({
        severity: "warning",
        code: "TARGET_TIGHT_CARDS",
        message:
          `Kart boşluğu ${clearance.toFixed(1)}mm — asgari ${MIN_CARD_CLEARANCE}mm. ` +
          `Kart zor girip çıkar. Dikiş payını ${params.stitchMargin}mm'den düşürmek ` +
          `her 0.5mm'de 1mm boşluk kazandırır.`,
      });
    } else if (clearance < 5) {
      diagnostics.push({
        severity: "warning",
        code: "TARGET_SNUG_CARDS",
        message:
          `Kart boşluğu ${clearance.toFixed(1)}mm — çalışır ama sıkı. ` +
          `Rahat değer 7.4mm (belgelenmiş 100mm bölme genişliğinden).`,
      });
    }

    const cover = walletHeight - billGeo.banknote.height;
    if (cover < 0) {
      diagnostics.push({
        severity: "error",
        code: "TARGET_TOO_SHORT",
        message:
          `Kapalı yükseklik ${walletHeight}mm — ${billGeo.banknote.label} ` +
          `${billGeo.banknote.height}mm. Banknot cüzdandan taşar.`,
      });
    } else if (cover < 6) {
      diagnostics.push({
        severity: "warning",
        code: "TARGET_LOW_COVER",
        message:
          `Banknot örtüsü ${cover.toFixed(1)}mm — önerilen 6mm. Para bölmenin ` +
          `ağzından görünür ve kenarları yıpranır. Daha küçük kupür ` +
          `hedefliyorsan sorun değil.`,
      });
    }

    const stackRoom = walletHeight - 2 * params.stitchMargin;
    if (slotGeo.stackHeight > stackRoom) {
      const maxReveal =
        n > 1 ? (stackRoom - CARD_ID1.height) / (n - 1) : Number.POSITIVE_INFINITY;
      diagnostics.push({
        severity: "error",
        code: "TARGET_SLOTS_OVERFLOW",
        message:
          `${n} yuva ${slotGeo.stackHeight.toFixed(1)}mm yer istiyor, ` +
          `${stackRoom.toFixed(1)}mm var. Kademeyi en fazla ` +
          `${maxReveal.toFixed(1)}mm yap ya da yuva sayısını azalt.`,
      });
    }
  }

  const openWidth = targeted ? 2 * panelWidth : Math.max(widthFromCards, widthFromBill);

  // Hedef modda banknot kontrolü TARGET_LOW_COVER ile zaten yapılıyor.
  // İkisini birden çalıştırmak aynı şey için hem hata hem uyarı üretir;
  // üstelik hedef ölçü bilinçli bir tercih, "hata" demek doğru değil.
  for (const d of validateBillPocket(
    {
      currency: params.currency,
      leatherThickness: params.innerThickness,
      stitchMargin: params.stitchMargin,
    },
    walletHeight,
  )) {
    if (targeted && d.code === "BILL_STICKS_OUT") continue;
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

  if (!targeted && widthFromBill > widthFromCards) {
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
    stitchedHoles: outerPlan.totalHoles,
    pitch: outerPlan.pitch,
    fitsA4,
    metrics: [
      {
        label: "kapalı ölçü",
        value: `${panelWidth.toFixed(1)} × ${walletHeight.toFixed(1)} mm`,
      },
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
ODK_EOF_0

echo "==> packages/patterns/src/cardholder.ts"
cat > packages/patterns/src/cardholder.ts << 'ODK_EOF_1'
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
ODK_EOF_1

echo "==> packages/patterns/src/tote.ts"
cat > packages/patterns/src/tote.ts << 'ODK_EOF_2'
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
    // Çantada İKİ dikiş var: körük–ön panel ve körük–arka panel.
    stitchedHoles: masterPlan.totalHoles * 2,
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
ODK_EOF_2

echo "==> packages/patterns/src/costing.ts"
cat > packages/patterns/src/costing.ts << 'ODK_EOF_3'
import type { Mm } from "@odk/geometry";
import { polylineLength, signedArea } from "@odk/geometry";
import type { PatternResult } from "./cardholder.js";

/**
 * MALİYET VE FİYAT TAHMİNİ
 *
 * ═══════════════════════════════════════════════════════════════════════
 * NE HESAPLANIR, NE SORULUR
 * ═══════════════════════════════════════════════════════════════════════
 *
 * Motor iki şeyi KESİN biliyor çünkü kalıbı kendisi üretti:
 *   - deri alanı (parça poligonlarının alanı × adet)
 *   - iş yükü göstergeleri (delik sayısı, kesim çevresi, parça sayısı)
 *
 * Motor iki şeyi BİLEMEZ:
 *   - deri desi fiyatı (tabakhaneye, ülkeye, aya göre değişir)
 *   - saatlik işçilik (atölyeye ve ustaya göre değişir)
 *
 * Bu yüzden alan ve süre hesaplanır, fiyatlar kullanıcıdan alınır.
 * Uydurma bir deri fiyatı gömmek, sayıya gereksiz bir güven kazandırır;
 * ilk aydan sonra yanlış olur ve kimse fark etmez.
 *
 * ⚠ SÜRE KATSAYILARI GEÇİCİ. Tek dayanak, bir kaynağın "bir bifold için
 * 2–4 saat dikiş bekleyin" ifadesi. Kendi işini ölçüp katsayıları
 * düzeltmen gerekiyor — arayüz bunu değiştirilebilir yapıyor.
 */

export interface CostRates {
  readonly currency: string;
  /** Deri fiyatı, para birimi / desimetrekare. */
  readonly leatherPerDm2: number;
  readonly labourPerHour: number;
  /** İplik, tutkal, kenar boyası — saat başına sarf. */
  readonly consumablesPerHour: number;
  /** Fermuar, çıtçıt, halka gibi parçalar (toplam). */
  readonly hardware: number;
  /** Genel gider oranı (kira, elektrik, alet aşınması). 0.15 = %15. */
  readonly overheadRate: number;
  /** Kâr marjı. 0.4 = maliyetin üstüne %40. */
  readonly marginRate: number;
  /** KDV oranı; 0 verilirse fiyat KDV'siz gösterilir. */
  readonly vatRate: number;
}

export const DEFAULT_RATES: CostRates = {
  currency: "TL",
  // ⚠ Bu sayılar YER TUTUCU. Kendi tedarikçi fiyatlarını gir.
  leatherPerDm2: 45,
  labourPerHour: 350,
  consumablesPerHour: 40,
  hardware: 0,
  overheadRate: 0.15,
  marginRate: 0.4,
  vatRate: 0.2,
};

/**
 * ⚠ GEÇİCİ süre katsayıları.
 *
 * holesPerHour için tek dayanak: "bir bifold için 2–4 saat dikiş
 * bekleyin". Bizim bifold'un çevresi ~96 delik; 50 delik/saat bu aralığın
 * (1.9 saat) alt ucuna denk geliyor ve deneyimli bir usta için makul.
 * Yeni başlayan için 25–30 daha gerçekçi.
 */
export interface TimeModel {
  /** Eyer dikişi hızı: saatte kaç delikten geçiliyor. */
  readonly holesPerHour: number;
  /**
   * Delik açma hızı (saatte delik).
   *
   * Dikişten çok daha hızlı: iron bir vuruşta 4–6 delik açıyor.
   * Ayrı sayılmak zorunda çünkü DELME parça başına, DİKİŞ dikiş hattı
   * başına yapılıyor.
   */
  readonly punchesPerHour: number;
  /** Parça başına sabit kesim süresi (dakika). */
  readonly minutesPerPiece: number;
  /** 100mm kesim çevresi başına dakika. */
  readonly minutesPer100mmCut: number;
  /** 100mm bitmiş kenar başına dakika (zımpara + boya + cila). */
  readonly minutesPer100mmEdge: number;
  /**
   * Bitmiş kenar tahmini için en büyük parçanın çevresine uygulanan
   * çarpan.
   *
   * Bütün parçaların çevresini toplamak YANLIŞ: iç parçaların kenarları
   * montajda gizleniyor, yalnızca dış çevre ve yuva ağızları
   * cilalanıyor. En büyük parçanın çevresi + %30 makul bir yaklaşım.
   */
  readonly edgePerimeterFactor: number;
  /** Yapıştırma ve montaj için sabit süre (dakika). */
  readonly assemblyMinutes: number;
  /** Parça başına ek montaj süresi (dakika). */
  readonly assemblyMinutesPerPiece: number;
}

export const DEFAULT_TIME_MODEL: TimeModel = {
  holesPerHour: 50,
  punchesPerHour: 500,
  minutesPerPiece: 3,
  minutesPer100mmCut: 1.5,
  minutesPer100mmEdge: 8,
  edgePerimeterFactor: 1.3,
  assemblyMinutes: 15,
  assemblyMinutesPerPiece: 3,
};

/**
 * Deri fire katsayısı.
 *
 * Post düzgün bir dikdörtgen değil; kenarlar, karın bölgesi ve kusurlu
 * yerler kullanılamıyor. Küçük deri işlerinde %25–40 fire tipik.
 *
 * ⚠ 1.35 geçici. Kendi postundan gerçekte kaç ürün çıktığını sayıp
 * düzeltmen gerekiyor.
 */
export const DEFAULT_WASTE_FACTOR = 1.35;

export interface CostBreakdown {
  readonly currency: string;
  /** Parçaların net alanı. */
  readonly netAreaDm2: number;
  /** Fire dahil satın alınması gereken alan. */
  readonly grossAreaDm2: number;
  readonly wasteFactor: number;
  readonly leatherCost: number;

  readonly cuttingHours: number;
  readonly punchingHours: number;
  readonly stitchingHours: number;
  readonly edgeHours: number;
  readonly assemblyHours: number;
  readonly totalHours: number;

  readonly labourCost: number;
  readonly consumablesCost: number;
  readonly hardwareCost: number;

  /** Deri + işçilik + sarf + donanım. */
  readonly directCost: number;
  readonly overhead: number;
  readonly totalCost: number;
  readonly margin: number;
  /** KDV hariç önerilen satış fiyatı. */
  readonly priceExVat: number;
  readonly vat: number;
  readonly priceIncVat: number;

  /** Deri maliyetinin toplam maliyet içindeki payı. */
  readonly leatherShare: number;
  readonly labourShare: number;
}

/** Poligonun mutlak alanı, mm². */
function pieceAreaMm2(poly: readonly { readonly x: Mm; readonly y: Mm }[]): number {
  return Math.abs(signedArea(poly));
}

export function estimateCost(
  pattern: PatternResult,
  rates: CostRates = DEFAULT_RATES,
  time: TimeModel = DEFAULT_TIME_MODEL,
  wasteFactor: number = DEFAULT_WASTE_FACTOR,
): CostBreakdown {
  let areaMm2 = 0;
  let cutPerimeter = 0;
  let punchedHoles = 0;
  let pieceCount = 0;
  let maxPerimeter = 0;

  for (const p of pattern.pieces) {
    const q = p.quantity;
    areaMm2 += pieceAreaMm2(p.cutLine) * q;
    const perimeter = polylineLength(p.cutLine, true);
    cutPerimeter += perimeter * q;
    maxPerimeter = Math.max(maxPerimeter, perimeter);
    // DELME parça başına: her parçanın kendi delikleri açılıyor.
    punchedHoles += (p.stitchPlan?.totalHoles ?? 0) * q;
    pieceCount += q;
  }

  // DİKİŞ hattı başına: iplik bütün katmanlardan bir kerede geçiyor.
  const stitchedHoles = pattern.summary.stitchedHoles;
  const edgeLength = maxPerimeter * time.edgePerimeterFactor;

  const netAreaDm2 = areaMm2 / 10000;
  const grossAreaDm2 = netAreaDm2 * wasteFactor;
  const leatherCost = grossAreaDm2 * rates.leatherPerDm2;

  const cuttingHours =
    (pieceCount * time.minutesPerPiece +
      (cutPerimeter / 100) * time.minutesPer100mmCut) /
    60;
  const punchingHours = punchedHoles / Math.max(1, time.punchesPerHour);
  const stitchingHours = stitchedHoles / Math.max(1, time.holesPerHour);
  const edgeHours = ((edgeLength / 100) * time.minutesPer100mmEdge) / 60;
  const assemblyHours =
    (time.assemblyMinutes + pieceCount * time.assemblyMinutesPerPiece) / 60;
  const totalHours =
    cuttingHours + punchingHours + stitchingHours + edgeHours + assemblyHours;

  const labourCost = totalHours * rates.labourPerHour;
  const consumablesCost = totalHours * rates.consumablesPerHour;
  const hardwareCost = rates.hardware;

  const directCost = leatherCost + labourCost + consumablesCost + hardwareCost;
  const overhead = directCost * rates.overheadRate;
  const totalCost = directCost + overhead;
  const margin = totalCost * rates.marginRate;
  const priceExVat = totalCost + margin;
  const vat = priceExVat * rates.vatRate;

  return {
    currency: rates.currency,
    netAreaDm2,
    grossAreaDm2,
    wasteFactor,
    leatherCost,
    cuttingHours,
    punchingHours,
    stitchingHours,
    edgeHours,
    assemblyHours,
    totalHours,
    labourCost,
    consumablesCost,
    hardwareCost,
    directCost,
    overhead,
    totalCost,
    margin,
    priceExVat,
    vat,
    priceIncVat: priceExVat + vat,
    leatherShare: totalCost > 0 ? leatherCost / totalCost : 0,
    labourShare: totalCost > 0 ? labourCost / totalCost : 0,
  };
}

export interface CostNote {
  readonly severity: "info" | "warning";
  readonly message: string;
}

/**
 * Hesabın kendisi hakkında uyarılar.
 *
 * Bir fiyat sayısı, dayandığı varsayımlar görünmediğinde tehlikeli.
 * Bu notlar sayının nereden geldiğini ve nerede kırılgan olduğunu
 * söylüyor.
 */
export function costNotes(
  breakdown: CostBreakdown,
  rates: CostRates = DEFAULT_RATES,
): CostNote[] {
  const notes: CostNote[] = [];

  notes.push({
    severity: "warning",
    message:
      `Alan ve süre kalıptan hesaplandı; deri fiyatı (${rates.leatherPerDm2} ` +
      `${rates.currency}/dm²) ve işçilik (${rates.labourPerHour} ` +
      `${rates.currency}/saat) senin girdiğin değerler. Bu ikisi doğru ` +
      `değilse fiyat da doğru değil.`,
  });

  notes.push({
    severity: "warning",
    message:
      `Dikiş süresi ${breakdown.stitchingHours.toFixed(1)} saat olarak ` +
      `hesaplandı. Bu, saatte 50 delik varsayımına dayanıyor ve GEÇİCİ bir ` +
      `katsayı. İlk ürünü yaparken süreni tut, katsayıyı düzelt.`,
  });

  if (breakdown.labourShare > 0.7) {
    notes.push({
      severity: "info",
      message:
        `Maliyetin %${(breakdown.labourShare * 100).toFixed(0)}'i işçilik. ` +
        `El yapımı deride normal; fiyatı düşürmenin yolu daha ucuz deri ` +
        `değil, daha hızlı çalışmak ya da daha az delik.`,
    });
  }

  if (breakdown.leatherShare > 0.5) {
    notes.push({
      severity: "info",
      message:
        `Maliyetin %${(breakdown.leatherShare * 100).toFixed(0)}'i deri. ` +
        `Fire katsayısı ${breakdown.wasteFactor} — parçaları posta daha iyi ` +
        `yerleştirmek burada belirgin kazanç sağlar.`,
    });
  }

  if (breakdown.totalHours > 8) {
    notes.push({
      severity: "info",
      message:
        `Toplam ${breakdown.totalHours.toFixed(1)} saat — bir günlük işten ` +
        `fazla. Fiyatlandırırken bunun bir seferde bitmeyeceğini hesaba kat.`,
    });
  }

  return notes;
}
ODK_EOF_3

echo "==> packages/patterns/src/costing.test.ts"
cat > packages/patterns/src/costing.test.ts << 'ODK_EOF_4'
import { describe, it, expect } from "vitest";
import {
  DEFAULT_RATES,
  DEFAULT_TIME_MODEL,
  DEFAULT_WASTE_FACTOR,
  costNotes,
  estimateCost,
} from "./costing.js";
import { BIFOLD_DEFAULTS, generateBifold } from "./bifold.js";
import { TOTE_DEFAULTS, generateTote } from "./tote.js";

const wallet95 = generateBifold({
  ...BIFOLD_DEFAULTS,
  cardSlotsPerSide: 2,
  stitchMargin: 3,
  reveal: 12,
  targetClosedWidth: 95,
  targetClosedHeight: 75,
});

describe("alan hesabı", () => {
  const c = estimateCost(wallet95);

  it("net alan parçaların toplamı", () => {
    // Kaba kontrol: iki panel ~190×75 + yuvalar. 20–40 dm² arası saçma
    // olurdu; bir cüzdan 2–5 dm² mertebesinde.
    expect(c.netAreaDm2).toBeGreaterThan(1.5);
    expect(c.netAreaDm2).toBeLessThan(6);
  });

  it("brüt alan fire kadar fazla", () => {
    expect(c.grossAreaDm2).toBeCloseTo(c.netAreaDm2 * DEFAULT_WASTE_FACTOR, 9);
  });

  it("çanta cüzdandan çok daha fazla deri istiyor", () => {
    const bag = estimateCost(generateTote(TOTE_DEFAULTS));
    expect(bag.netAreaDm2).toBeGreaterThan(c.netAreaDm2 * 2.5);
  });
});

describe("süre modeli", () => {
  const c = estimateCost(wallet95);

  it("dikiş süresi DİKİLEN deliğe göre, parça toplamına göre değil", () => {
    // Aynı fiziksel delik her katmanda ayrı sayılırsa süre 2–3 katına
    // çıkıyor; iplik bütün katmanlardan bir kerede geçiyor.
    expect(c.stitchingHours).toBeCloseTo(
      wallet95.summary.stitchedHoles / DEFAULT_TIME_MODEL.holesPerHour,
      9,
    );
    const perPieceSum = wallet95.pieces.reduce(
      (a, p) => a + (p.stitchPlan?.totalHoles ?? 0) * p.quantity,
      0,
    );
    expect(perPieceSum).toBeGreaterThan(wallet95.summary.stitchedHoles * 2);
  });

  it("delme ayrı sayılıyor ve dikişten hızlı", () => {
    expect(c.punchingHours).toBeGreaterThan(0);
    expect(c.punchingHours).toBeLessThan(c.stitchingHours);
  });

  it("bifold dikiş süresi belgelenmiş 2–4 saat bandına yakın", () => {
    // Tek dayanağımız: 'bir bifold için 2–4 saat dikiş bekleyin'.
    // Modelin bu mertebeyi vermesi, katsayının tamamen uydurma
    // olmadığının tek göstergesi.
    const full = estimateCost(generateBifold(BIFOLD_DEFAULTS));
    expect(full.stitchingHours).toBeGreaterThan(1);
    expect(full.stitchingHours).toBeLessThan(6);
  });

  it("toplam süre bileşenlerin toplamı", () => {
    expect(c.totalHours).toBeCloseTo(
      c.cuttingHours + c.punchingHours + c.stitchingHours + c.edgeHours + c.assemblyHours,
      9,
    );
  });

  it("delik başına adım artınca dikiş süresi düşüyor", () => {
    const fine = estimateCost(
      generateBifold({ ...BIFOLD_DEFAULTS, pitch: 3 }),
    );
    const coarse = estimateCost(
      generateBifold({ ...BIFOLD_DEFAULTS, pitch: 5 }),
    );
    expect(coarse.stitchingHours).toBeLessThan(fine.stitchingHours);
  });
});

describe("fiyat zinciri", () => {
  const c = estimateCost(wallet95);

  it("doğrudan maliyet bileşenlerin toplamı", () => {
    expect(c.directCost).toBeCloseTo(
      c.leatherCost + c.labourCost + c.consumablesCost + c.hardwareCost,
      6,
    );
  });

  it("genel gider ve marj sırayla uygulanıyor", () => {
    expect(c.overhead).toBeCloseTo(c.directCost * DEFAULT_RATES.overheadRate, 6);
    expect(c.totalCost).toBeCloseTo(c.directCost + c.overhead, 6);
    expect(c.margin).toBeCloseTo(c.totalCost * DEFAULT_RATES.marginRate, 6);
    expect(c.priceExVat).toBeCloseTo(c.totalCost + c.margin, 6);
  });

  it("KDV fiyatın üstüne biniyor", () => {
    expect(c.priceIncVat).toBeCloseTo(c.priceExVat * (1 + DEFAULT_RATES.vatRate), 6);
  });

  it("KDV sıfırsa fiyat değişmiyor", () => {
    const noVat = estimateCost(wallet95, { ...DEFAULT_RATES, vatRate: 0 });
    expect(noVat.priceIncVat).toBeCloseTo(noVat.priceExVat, 9);
  });

  it("deri fiyatı iki katına çıkınca satış fiyatı artıyor ama iki katına çıkmıyor", () => {
    // İşçilik payı büyük olduğu için deri fiyatı fiyatı doğrusal sürüklemez.
    const base = estimateCost(wallet95);
    const pricey = estimateCost(wallet95, {
      ...DEFAULT_RATES,
      leatherPerDm2: DEFAULT_RATES.leatherPerDm2 * 2,
    });
    expect(pricey.priceExVat).toBeGreaterThan(base.priceExVat);
    expect(pricey.priceExVat).toBeLessThan(base.priceExVat * 2);
  });

  it("paylar toplamda %100'ü geçmiyor", () => {
    expect(c.leatherShare + c.labourShare).toBeLessThanOrEqual(1);
  });
});

describe("uyarı notları", () => {
  it("fiyatların kullanıcıdan geldiğini her zaman söylüyor", () => {
    const notes = costNotes(estimateCost(wallet95));
    expect(notes.some((n) => n.message.includes("senin girdiğin"))).toBe(true);
  });

  it("dikiş katsayısının geçici olduğunu söylüyor", () => {
    const notes = costNotes(estimateCost(wallet95));
    expect(notes.some((n) => n.message.includes("GEÇİCİ"))).toBe(true);
  });

  it("işçilik payı yüksekse bunu belirtiyor", () => {
    const notes = costNotes(
      estimateCost(wallet95, { ...DEFAULT_RATES, leatherPerDm2: 1 }),
    );
    expect(notes.some((n) => n.message.includes("işçilik"))).toBe(true);
  });
});
ODK_EOF_4

echo "==> packages/patterns/src/index.ts"
cat > packages/patterns/src/index.ts << 'ODK_EOF_5'
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
export * from "./costing.js";
export * from "./instructions.js";
export * from "./stitchprojection.js";
ODK_EOF_5

echo "==> apps/web/src/engine.ts"
cat > apps/web/src/engine.ts << 'ODK_EOF_6'
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
  DEFAULT_RATES,
  costNotes,
  estimateCost,
} from "@odk/patterns";

export { stitchSummary as stitchSummaryFor } from "@odk/geometry";
ODK_EOF_6

echo "==> apps/web/src/App.tsx"
cat > apps/web/src/App.tsx << 'ODK_EOF_7'
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
  DEFAULT_RATES,
  costNotes,
  estimateCost,
} from "./engine.js";
import type { CostRates } from "@odk/patterns";

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
  const [rates, setRates] = useState<CostRates>(DEFAULT_RATES);

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
          <legend>Maliyet</legend>
          <p className="hint">
            Alan ve süre kalıptan hesaplanıyor. Fiyatları sen giriyorsun —
            deri ve işçilik ücretleri tabakhaneye, ülkeye ve aya göre
            değişiyor, motor bunları bilemez.
          </p>
          {(
            [
              ["leatherPerDm2", "Deri", "/dm²", 0, 500, 5],
              ["labourPerHour", "İşçilik", "/saat", 0, 2000, 25],
              ["consumablesPerHour", "Sarf", "/saat", 0, 300, 5],
              ["hardware", "Donanım", "toplam", 0, 2000, 25],
            ] as const
          ).map(([key, label, unit, min, max, step]) => (
            <Slider
              key={key}
              label={`${label} (${unit})`}
              value={rates[key]}
              min={min}
              max={max}
              step={step}
              onChange={(v) => setRates((p) => ({ ...p, [key]: v }))}
            />
          ))}
          <Slider
            label="Genel gider"
            value={Math.round(rates.overheadRate * 100)}
            min={0}
            max={60}
            step={5}
            unit="%"
            onChange={(v) => setRates((p) => ({ ...p, overheadRate: v / 100 }))}
          />
          <Slider
            label="Kâr marjı"
            value={Math.round(rates.marginRate * 100)}
            min={0}
            max={150}
            step={5}
            unit="%"
            onChange={(v) => setRates((p) => ({ ...p, marginRate: v / 100 }))}
          />
          <Slider
            label="KDV"
            value={Math.round(rates.vatRate * 100)}
            min={0}
            max={30}
            step={1}
            unit="%"
            onChange={(v) => setRates((p) => ({ ...p, vatRate: v / 100 }))}
          />
        </fieldset>

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
          <Result value={result.value} ctx={ctx} family={family} rates={rates} />
        )}
      </main>
    </div>
  );
}

function Result({
  value,
  ctx,
  family,
  rates,
}: {
  value: ReturnType<typeof generateCardHolder>;
  ctx: CardHolderParams | BifoldParams | (ToteParams & { kind: "canta" });
  family: FamilyId;
  rates: CostRates;
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

      <CostPanel value={value} rates={rates} />

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


function CostPanel({
  value,
  rates,
}: {
  value: ReturnType<typeof generateCardHolder>;
  rates: CostRates;
}) {
  const c = estimateCost(value, rates);
  const notes = costNotes(c, rates);
  const money = (n: number) => `${Math.round(n).toLocaleString("tr-TR")} ${c.currency}`;
  const hours = (n: number) => `${n.toFixed(2)} sa`;

  return (
    <section className="cost">
      <h3>Maliyet ve önerilen fiyat</h3>
      <div className="cost-headline">
        <span className="cost-price">{money(c.priceIncVat)}</span>
        <span className="cost-sub">
          KDV dahil · KDV hariç {money(c.priceExVat)} · maliyet {money(c.totalCost)}
        </span>
      </div>

      <div className="columns">
        <table className="readout">
          <caption>Malzeme ve süre</caption>
          <tbody>
            <tr>
              <th scope="row">net deri</th>
              <td className="num">{c.netAreaDm2.toFixed(2)} dm²</td>
            </tr>
            <tr>
              <th scope="row">fire dahil</th>
              <td className="num">{c.grossAreaDm2.toFixed(2)} dm²</td>
            </tr>
            <tr>
              <th scope="row">kesim</th>
              <td className="num">{hours(c.cuttingHours)}</td>
            </tr>
            <tr>
              <th scope="row">delme</th>
              <td className="num">{hours(c.punchingHours)}</td>
            </tr>
            <tr>
              <th scope="row">dikiş</th>
              <td className="num">{hours(c.stitchingHours)}</td>
            </tr>
            <tr>
              <th scope="row">kenar</th>
              <td className="num">{hours(c.edgeHours)}</td>
            </tr>
            <tr>
              <th scope="row">montaj</th>
              <td className="num">{hours(c.assemblyHours)}</td>
            </tr>
            <tr>
              <th scope="row">toplam</th>
              <td className="num">{hours(c.totalHours)}</td>
            </tr>
          </tbody>
        </table>

        <table className="readout">
          <caption>Fiyat zinciri</caption>
          <tbody>
            <tr>
              <th scope="row">deri</th>
              <td className="num">{money(c.leatherCost)}</td>
            </tr>
            <tr>
              <th scope="row">işçilik</th>
              <td className="num">{money(c.labourCost)}</td>
            </tr>
            <tr>
              <th scope="row">sarf</th>
              <td className="num">{money(c.consumablesCost)}</td>
            </tr>
            {c.hardwareCost > 0 && (
              <tr>
                <th scope="row">donanım</th>
                <td className="num">{money(c.hardwareCost)}</td>
              </tr>
            )}
            <tr>
              <th scope="row">genel gider</th>
              <td className="num">{money(c.overhead)}</td>
            </tr>
            <tr>
              <th scope="row">maliyet</th>
              <td className="num">{money(c.totalCost)}</td>
            </tr>
            <tr>
              <th scope="row">kâr</th>
              <td className="num">{money(c.margin)}</td>
            </tr>
            <tr>
              <th scope="row">KDV</th>
              <td className="num">{money(c.vat)}</td>
            </tr>
          </tbody>
        </table>
      </div>

      <ul className="diagnostics">
        {notes.map((n, i) => (
          <li key={i} className="diagnostic" data-severity={n.severity}>
            <code>{n.severity === "warning" ? "DİKKAT" : "NOT"}</code>
            <span>{n.message}</span>
          </li>
        ))}
      </ul>
    </section>
  );
}
ODK_EOF_7

echo "==> apps/web/src/styles.css"
cat > apps/web/src/styles.css << 'ODK_EOF_8'
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

/* ── Maliyet ───────────────────────────────────────────────────────── */

.cost {
  margin-bottom: 32px;
  max-width: 720px;
}

.cost h3 {
  font-size: 14px;
  font-weight: 600;
  margin: 0 0 12px;
}

.cost-headline {
  display: flex;
  flex-wrap: wrap;
  align-items: baseline;
  gap: 6px 14px;
  padding: 14px 16px;
  background: var(--mat);
  border-left: 2px solid var(--brass);
  margin-bottom: 18px;
}

.cost-price {
  font-family: var(--mono);
  font-size: 26px;
  font-weight: 500;
  color: var(--brass);
  font-variant-numeric: tabular-nums;
}

.cost-sub {
  font-family: var(--mono);
  font-size: 11px;
  color: var(--bone-dim);
}

.diagnostic[data-severity="info"] {
  border-left-color: var(--chalk);
}
ODK_EOF_8

echo "==> Testler"
pnpm test

echo "==> Typecheck"
pnpm typecheck

echo "==> Arayuz derlemesi"
pnpm --filter @odk/web build

cat << 'ODK_DONE'

============================================================
HEDEF OLCU + MALIYET HESABI
============================================================

95 x 75mm, 2+2 = 4 yuva, dikis payi 3mm:
  kapali 95.0 x 75.0mm · acik 203.6 x 74.4mm
  kat payi 11.83mm · bos 6.20mm · kart yuklu 9.24mm
  UYARI: kart boslugu 3.4mm (rahat deger 7.4mm)
  UYARI: banknot ortusu 3mm (onerilen 6mm)

Maliyet (varsayilan yer tutucu fiyatlarla):
  4.95 dm2 net -> 6.69 dm2 fire dahil
  4.64 saat (kesim .86 delme .52 dikis 1.76 kenar .95 montaj .55)
  maliyet 2426 TL · fiyat 3396 TL · KDVli 4075 TL

Git:
  git add -A
  git commit -m "Hedef kapali olcu modu ve maliyet hesabi

HEDEF OLCU
- targetClosedWidth/Height verilirse olcu SABITLENIYOR, motor kisitlarin
  saglanip saglanmadigini raporluyor. Sessizce olcuyu degistirmek de,
  kisiti yok saymak da kullaniciyi yaniltirdi.
- 95mm genislik kart (85.6mm) + iki yanda dikis payi icin sinirda:
  3mm payla 3.4mm bosluk kaliyor, rahat deger 7.4mm. Uyari cikiyor.
- 75mm yukseklik 200 TL banknotunu (72mm) 3mm ortuyor; onerilen 6mm.
- Hedef modda BILL_STICKS_OUT hatasi bastiriliyor: ayni sey icin hem
  hata hem uyari uretmek gurultu, ustelik hedef olcu bilincli tercih.

MALIYET
- Motor alan ve sureyi HESAPLIYOR (kalibi kendisi uretti), fiyatlari
  KULLANICIDAN aliyor. Uydurma deri fiyati gommek sayiya gereksiz guven
  kazandirir ve ilk aydan sonra yanlis olur.
- DIKIS vs DELME ayrildi. Ilk surumde parca basina delikleri topluyordum
  ve cuzdan icin 5.16 saat cikiyordu; iplik butun katmanlardan BIR
  KEREDE geciyor. Ayni fiziksel delik her katmanda ayri sayilmamali.
  Duzeltince 1.76 saat — belgelenmis '2-4 saat' bandinin alt ucu.
- KENAR hesabi da duzeltildi: butun parcalarin cevresini toplamak
  yanlis, ic parcalarin kenarlari montajda gizleniyor. En buyuk parcanin
  cevresi + %30.
- summary.stitchedHoles eklendi: cantada iki dikis var (on ve arka
  panel), cuzdanda tek cevre dikisi.
- costNotes(): fiyatin hangi varsayimlara dayandigini ve nerede
  kirilgan oldugunu soyluyor.

- 367 test geciyor"

  git push
  vercel --prod

⚠ SURE KATSAYILARI GECICI. Tek dayanak 'bifold icin 2-4 saat dikis'
ifadesi. Ilk urunu yaparken sureni tut ve katsayilari duzelt.
ODK_DONE
