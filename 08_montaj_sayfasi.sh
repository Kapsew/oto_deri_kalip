#!/usr/bin/env bash
#
# 08_montaj_sayfasi.sh — Ticari kalip incelemesinden cikan eklemeler
#
# 1) Montaj sayfasi: parcalarin bitmis urundeki yerlesimi
# 2) Olcu cizgileri: uzatma cizgileri + uc isaretleri + metin
# 3) Parca kodlari (A, B, C) — talimatlarda atif icin
# 4) Delik basma varsayilani ACIK oldu
#
# Repo kokunde calistir. Idempotent.

set -euo pipefail

if [ ! -f "pnpm-workspace.yaml" ] || [ ! -d "packages/print" ]; then
  echo "HATA: Repo kokunde calistirilmali ve 05 uygulanmis olmali." >&2
  exit 1
fi

echo "==> packages/patterns/src/cardholder.ts"
cat > packages/patterns/src/cardholder.ts << 'ODK_EOF_0'
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
      code: "B",
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
      code: "C",
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

  // --- Montaj yerleşimi -------------------------------------------------
  //
  // Yuvalar dış kabuğun ÖN paneline oturuyor. En alttaki yuva en dipte;
  // her yuva bir kademe yukarıda, böylece ağızları basamak oluşturuyor
  // ve kartlar parmakla ayrılabiliyor.
  //
  // En üstteki yuvanın üst kenarı tam olarak panel yüksekliğine denk
  // geliyor: (n−1)·kademe + kart yüksekliği + dikiş payı = panelHeight.
  const assembly: AssemblyPlacement[] = [];
  const n = Math.max(0, Math.floor(params.cardCount));
  for (let i = 0; i < n; i++) {
    // i = 0 en dipteki yuva. T-slot yapımda yalnızca en dip düz
    // dikdörtgen, üsttekiler T biçimli.
    const isRect = params.construction === "stacked" || i === 0;
    assembly.push({
      pieceId: isRect ? "slot-rect" : "slot-t",
      code: isRect ? "B" : `C-${i}`,
      x: 0,
      y: i * params.reveal,
      layer: i + 1,
    });
  }

  return {
    pieces,
    assembly,
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
      panelHeight,
      totalHoles: outerPlan.totalHoles,
      pitch: outerPlan.pitch,
      fitsA4,
    },
  };
}

/** Kart genişliği/yüksekliği dışa açılıyor: arayüz etiketleri için. */
export const cardDimensions = { width: cardW, height: cardH };
ODK_EOF_0

echo "==> packages/print/src/pdf.ts"
cat > packages/print/src/pdf.ts << 'ODK_EOF_1'
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
import type { PatternResult, PatternPiece } from "@odk/patterns";
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
ODK_EOF_1

echo "==> packages/print/src/print.test.ts"
cat > packages/print/src/print.test.ts << 'ODK_EOF_2'
import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { PDFDocument } from "pdf-lib";
import { mmToPt } from "@odk/geometry";
import { DEFAULT_PARAMS, generateCardHolder } from "@odk/patterns";
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
ODK_EOF_2

echo "==> apps/web/src/App.tsx"
cat > apps/web/src/App.tsx << 'ODK_EOF_3'
import { useMemo, useState } from "react";
import type {
  CardHolderParams,
  CardOrientation,
  SlotConstruction,
} from "@odk/patterns";
import {
  DEFAULT_PARAMS,
  generateCardHolder,
  stitchSummaryFor,
} from "./engine.js";
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
  const [params, setParams] = useState<CardHolderParams>(DEFAULT_PARAMS);
  const [print, setPrint] = useState<PrintState>(INITIAL_PRINT);

  const set = <K extends keyof CardHolderParams>(
    key: K,
    value: CardHolderParams[K],
  ) => setParams((p) => ({ ...p, [key]: value }));

  const result = useMemo(() => {
    try {
      return { ok: true as const, value: generateCardHolder(params) };
    } catch (err) {
      return {
        ok: false as const,
        message: err instanceof Error ? err.message : String(err),
      };
    }
  }, [params]);

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
                    title: `Kartlık ${params.cardCount} yuva`,
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
          <Result value={result.value} params={params} />
        )}
      </main>
    </div>
  );
}

function Result({
  value,
  params,
}: {
  value: ReturnType<typeof generateCardHolder>;
  params: CardHolderParams;
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
          {params.cardCount} yuva · {params.construction === "t-slot" ? "T-slot" : "düz yığın"} ·{" "}
          {s.pitch}mm adım · {s.totalHoles} delik
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
ODK_EOF_3

echo "==> Testler"
pnpm test

echo "==> Typecheck"
pnpm typecheck

echo "==> Arayuz derlemesi"
pnpm --filter @odk/web build

cat << 'ODK_DONE'

============================================================
MONTAJ SAYFASI + OLCU CIZGILERI
============================================================

PDF artik: kapak -> MONTAJ -> desen sayfalari

Git:
  git add -A
  git commit -m "Montaj sayfasi, olcu cizgileri, parca kodlari

Ticari bir kalibin sunum konvansiyonlari incelendi (geometrisi DEGIL --
satin alinmis lisansli icerik, kutuphaneye alinmaz).

- Montaj sayfasi: yuvalarin dis kabuk uzerindeki kademe yerlesimi.
  Onceki surumde kalip birbirinden bagimsiz parcalar listesiydi;
  hangi parcanin nereye geldigi kullanicinin kafasindaydi.
- AssemblyPlacement: her parca ORNEGI icin konum (parcalar tipe gore
  gruplaniyor ama montaj her ornegi ayri gostermek zorunda)
- Olcu cizgileri: uzatma cizgileri, uc isaretleri, ortalanmis metin.
  Kullanici hangi iki nokta arasini olcecegini cizimden goruyor;
  etiketteki '99.4 x 194.4mm' bunu soylemiyor.
- Parca kodlari A/B/C: ad degisebilir, kod degismez
- printAllHoles VARSAYILANI ACIK oldu. Ilk gerekcem 'kullanici ironu
  kendisi yurur, basilmis nokta yaniltir' idi; yaygin is akisinin
  kagit sablonu deriye bantlayip ISARETLI NOKTALARDAN delmek oldugu
  goruldu. Kapali secenek duruyor.
- 254 test geciyor"

  git push
  vercel --prod
ODK_DONE
