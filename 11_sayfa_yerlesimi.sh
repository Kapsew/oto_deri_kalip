#!/usr/bin/env bash
#
# 11_sayfa_yerlesimi.sh — Doseme yerine sayfa bazli yerlestirme
#
# Parcalar 90 derece dondurulerek tek sayfaya sigdiriliyor.
# Hizalama hatasi artik urunun olcusune giremiyor.
#
# Repo kokunde calistir. Idempotent.

set -euo pipefail

if [ ! -f "pnpm-workspace.yaml" ] || [ ! -d "packages/print" ]; then
  echo "HATA: Repo kokunde calistirilmali ve 10 uygulanmis olmali." >&2
  exit 1
fi

echo "==> packages/print/src/layout.ts"
cat > packages/print/src/layout.ts << 'ODK_EOF_0'
import type { Mm } from "@odk/geometry";
import { EPS } from "@odk/geometry";
import type { PatternPiece } from "@odk/patterns";
import type { PaperSpec } from "./paper.js";
import { A4_PORTRAIT, printableArea, CALIBRATION_SQUARE } from "./paper.js";

/**
 * YERLEŞİM
 *
 * Parçalar önce tek bir "sanal tabakaya" diziliyor, sonra o tabaka
 * sayfalara bölünüyor. Tek mekanizma hem A4'e sığan küçük parçaları
 * hem de sığmayan büyükleri aynı şekilde ele alıyor — iki ayrı kod
 * yolu tutmaktan çok daha az hata üretir.
 */

export interface PlacedPiece {
  readonly piece: PatternPiece;
  /** Yerleşim koordinatında sol-alt köşe. */
  readonly x: Mm;
  readonly y: Mm;
  /** Yerleşimdeki ölçüler — döndürülmüşse takas edilmiş hâli. */
  readonly width: Mm;
  readonly height: Mm;
  /** 90° saat yönünün tersine döndürüldü mü? */
  readonly rotated: boolean;
}

/**
 * Parça yerel koordinatını yerleşim koordinatına çevirir.
 *
 * Döndürme burada, tek yerde uygulanıyor — kesim hattı, dikiş hattı,
 * delikler, kat çizgileri ve damar oku hepsi aynı dönüşümden geçiyor.
 * Ayrı ayrı döndürmek, damar okunun parçayla uyumsuz kalması gibi
 * sessiz hatalara açık olurdu.
 */
export function pieceToLayout(
  placed: PlacedPiece,
  point: { readonly x: Mm; readonly y: Mm },
  minX: Mm,
  minY: Mm,
): { readonly x: Mm; readonly y: Mm } {
  const lx = point.x - minX;
  const ly = point.y - minY;
  if (!placed.rotated) {
    return { x: placed.x + lx, y: placed.y + ly };
  }
  // 90° CCW: (lx, ly) -> (H - ly, lx). Döndürüldüğünde placed.width,
  // parçanın ORİJİNAL yüksekliğine eşit.
  return { x: placed.x + (placed.width - ly), y: placed.y + lx };
}

export interface SheetLayout {
  readonly placed: readonly PlacedPiece[];
  readonly width: Mm;
  readonly height: Mm;
}

/** Parçalar arası boşluk: makas payı. */
export const PIECE_GAP: Mm = 10;

/**
 * Her parçanın ÜSTÜNDE etiket için ayrılan şerit.
 *
 * Bu pay olmadan en üstteki parçanın etiketi tabakanın dışına düşüyor ve
 * sayfa kırpması onu yiyor — ilk üretilen PDF'te tam olarak bu oldu.
 * Etiket parçanın adını, adedini ve deri kalınlığını taşıdığı için
 * kaybolması, kullanıcının hangi parçayı hangi deriden keseceğini
 * bilememesi demek.
 */
export const LABEL_SPACE: Mm = 8;

/**
 * Raf (shelf) yerleştirme.
 *
 * Parçalar yüksekliğe göre azalan sırada dizilir; satır dolunca yeni
 * satıra geçilir. Optimal değil ama kalıp parçaları için fazlasıyla
 * yeterli: tipik bir kartlıkta 3–5 parça var, kağıt israfı birkaç mm.
 *
 * Tabaka genişliği basılabilir alandan dar tutulur; parça daha genişse
 * tabaka o parçaya göre genişler ve döşeme yatayda da bölünür.
 */
export function packPieces(
  pieces: readonly PatternPiece[],
  paper: PaperSpec = A4_PORTRAIT,
  gap: Mm = PIECE_GAP,
): SheetLayout {
  if (pieces.length === 0) {
    return { placed: [], width: 0, height: 0 };
  }

  const area = printableArea(paper);
  const widest = Math.max(...pieces.map((p) => p.width));
  const sheetWidth = Math.max(area.width, widest);

  const sorted = [...pieces].sort((a, b) => b.height - a.height);

  // Yerleştirme yukarıdan aşağı yapılıyor; her parça kendi yuvasının
  // ALT kısmına oturuyor, üstteki LABEL_SPACE etikete kalıyor.
  interface Slot {
    readonly piece: (typeof sorted)[number];
    readonly x: Mm;
    readonly topY: Mm;
    readonly slotHeight: Mm;
  }
  const slots: Slot[] = [];
  let shelfY = 0;
  let shelfHeight = 0;
  let cursorX = 0;

  for (const piece of sorted) {
    const slotHeight = piece.height + LABEL_SPACE;
    if (cursorX > 0 && cursorX + piece.width > sheetWidth) {
      shelfY += shelfHeight + gap;
      shelfHeight = 0;
      cursorX = 0;
    }
    slots.push({ piece, x: cursorX, topY: shelfY, slotHeight });
    cursorX += piece.width + gap;
    shelfHeight = Math.max(shelfHeight, slotHeight);
  }

  const height = shelfY + shelfHeight;

  // Tabaka koordinatı aşağıdan yukarı çevriliyor.
  const placed: PlacedPiece[] = slots.map((s) => ({
    piece: s.piece,
    x: s.x,
    y: height - s.topY - s.slotHeight,
    width: s.piece.width,
    height: s.piece.height,
    rotated: false,
  }));

  return { placed, width: sheetWidth, height };
}

// --- Sayfa bazlı yerleştirme (tercih edilen yol) ---------------------------

/**
 * SAYFA BAZLI YERLEŞTİRME — DÖŞEMEYE TERCİH EDİLİR.
 *
 * NEDEN: döşeme (tiling) parçayı iki sayfaya bölüyor ve kullanıcı
 * sayfaları elle hizalayıp yapıştırıyor. Hizalama hatası doğrudan
 * ürünün ölçüsüne giriyor — mikron hassasiyetle hesaplanmış bir kalıbı
 * yarım milimetrelik bir kaydırma anlamsız kılıyor.
 *
 * Çözüm iki adımlı:
 *   1) Parça düz hâlde sayfaya sığmıyorsa 90° DÖNDÜRÜLÜR. Bifold'un
 *      213.6 × 77.4mm dış kabuğu döndürülünce 77.4 × 213.6 oluyor ve
 *      190 × 263mm'lik basılabilir alana rahatça sığıyor.
 *   2) Yalnızca döndürülünce de sığmayan parçalar döşemeye kalıyor.
 *
 * Sonuç: tipik bir cüzdanda hiç hizalama gerekmiyor.
 */
export interface LayoutPage {
  readonly index: number;
  readonly placed: readonly PlacedPiece[];
}

export interface PageLayout {
  readonly pages: readonly LayoutPage[];
  /** Döndürülse bile tek sayfaya sığmayan parçalar — döşeme gerekiyor. */
  readonly oversized: readonly PatternPiece[];
  readonly rotatedCount: number;
}

interface Orientation {
  readonly width: Mm;
  readonly height: Mm;
  readonly rotated: boolean;
}

/**
 * Parçanın sayfaya sığan yönü. Düz hâl tercih edilir; yalnızca
 * sığmıyorsa döndürülür.
 */
function chooseOrientation(
  piece: PatternPiece,
  maxWidth: Mm,
  maxHeight: Mm,
  allowRotation: boolean,
): Orientation | undefined {
  const flat: Orientation = {
    width: piece.width,
    height: piece.height,
    rotated: false,
  };
  const turned: Orientation = {
    width: piece.height,
    height: piece.width,
    rotated: true,
  };
  const fits = (o: Orientation): boolean =>
    o.width <= maxWidth + EPS && o.height + LABEL_SPACE <= maxHeight + EPS;

  if (fits(flat)) return flat;
  if (allowRotation && fits(turned)) return turned;
  return undefined;
}

export function packPages(
  pieces: readonly PatternPiece[],
  paper: PaperSpec = A4_PORTRAIT,
  gap: Mm = PIECE_GAP,
  allowRotation = true,
): PageLayout {
  const area = printableArea(paper);
  const pages: LayoutPage[] = [];
  const oversized: PatternPiece[] = [];
  let rotatedCount = 0;

  interface Slot {
    readonly piece: PatternPiece;
    readonly o: Orientation;
    readonly x: Mm;
    readonly topY: Mm;
  }

  let current: Slot[] = [];
  let shelfTop = 0;
  let shelfHeight = 0;
  let cursorX = 0;

  const flush = (): void => {
    if (current.length === 0) return;
    pages.push({
      index: pages.length,
      placed: current.map((s) => ({
        piece: s.piece,
        x: s.x,
        y: area.height - s.topY - (s.o.height + LABEL_SPACE),
        width: s.o.width,
        height: s.o.height,
        rotated: s.o.rotated,
      })),
    });
    current = [];
    shelfTop = 0;
    shelfHeight = 0;
    cursorX = 0;
  };

  // Büyükten küçüğe: büyük parçalar önce yerleşince boşluk daha az kalıyor.
  const sorted = [...pieces].sort(
    (a, b) => b.width * b.height - a.width * a.height,
  );

  for (const piece of sorted) {
    const o = chooseOrientation(piece, area.width, area.height, allowRotation);

    if (o === undefined) {
      oversized.push(piece);
      continue;
    }
    if (o.rotated) rotatedCount += 1;

    const slotHeight = o.height + LABEL_SPACE;

    if (cursorX > EPS && cursorX + o.width > area.width + EPS) {
      shelfTop += shelfHeight + gap;
      shelfHeight = 0;
      cursorX = 0;
    }
    if (shelfTop + slotHeight > area.height + EPS) {
      flush();
    }

    current.push({ piece, o, x: cursorX, topY: shelfTop });
    cursorX += o.width + gap;
    shelfHeight = Math.max(shelfHeight, slotHeight);
  }

  flush();

  return { pages, oversized, rotatedCount };
}

// --- Çizgi biçimleri -------------------------------------------------------

/**
 * ÇİZGİ BİÇİMLERİ RENKLE DEĞİL DESENLE AYRIŞIR.
 *
 * Hedef kitlenin çoğunda renkli yazıcı yok. Renk tek ayırt edici olursa
 * siyah-beyaz çıktıda kesim ile dikiş hattı birbirine karışır ve
 * kullanıcı yanlış yerden keser.
 */
export interface LineStyle {
  readonly width: Mm;
  /** [çizgi, boşluk] mm. Boş dizi = sürekli. */
  readonly dash: readonly Mm[];
  readonly gray: number;
}

export const STYLES: Record<"cut" | "stitch" | "fold" | "glue" | "guide" | "trim", LineStyle> = {
  /**
   * Kesim: mümkün olduğunca ince.
   *
   * 0.2mm kalınlıkta bile "çizginin neresinden keseceğim" belirsizliği
   * iki kenarda 0.2mm kaybettirir. Daha ince basmak çoğu yazıcıda
   * çizginin kaybolmasına yol açar; 0.2 pratik alt sınır.
   */
  cut: { width: 0.2, dash: [], gray: 0 },
  stitch: { width: 0.25, dash: [2, 1.6], gray: 0.35 },
  fold: { width: 0.25, dash: [0.8, 1.6], gray: 0.45 },
  glue: { width: 0.15, dash: [1, 1], gray: 0.6 },
  guide: { width: 0.15, dash: [], gray: 0.7 },
  /** Sayfa kesme/hizalama hattı. */
  trim: { width: 0.2, dash: [3, 2], gray: 0.55 },
};

// --- Kalibrasyon -----------------------------------------------------------

export interface CalibrationResult {
  readonly factor: number;
  readonly ok: boolean;
  readonly message: string;
}

/**
 * Ölçülen kare kenarından ölçek düzeltme katsayısı.
 *
 * Kullanıcı 50mm'lik kareyi cetvelle ölçüp gerçekte kaç mm çıktığını
 * giriyor. Yazıcı %99 ölçekle bastıysa kare 49.5mm çıkar; içeriği
 * 50/49.5 = 1.0101 ile büyütürsek sonraki baskı doğru olur.
 *
 * Katsayı ±%10 dışına çıkarsa kabul edilmez: o kadar sapma yazıcı
 * ölçeğinden değil, yanlış ölçümden ya da yanlış birimden gelir
 * (örneğin kullanıcı inç ölçmüştür). Sessizce uygulamak kalıbı
 * tamamen bozardı.
 */
export function scaleFromMeasurement(
  measuredMm: number,
  nominalMm: number = CALIBRATION_SQUARE,
): CalibrationResult {
  if (!Number.isFinite(measuredMm) || measuredMm <= 0) {
    return {
      factor: 1,
      ok: false,
      message: "Ölçülen değer bir sayı olmalı ve sıfırdan büyük olmalı.",
    };
  }

  const factor = nominalMm / measuredMm;

  if (factor < 0.9 || factor > 1.1) {
    return {
      factor: 1,
      ok: false,
      message:
        `Ölçülen ${measuredMm}mm, beklenen ${nominalMm}mm — sapma %10'dan fazla. ` +
        `Yazıcı ölçeği bu kadar kaymaz. Cetvelin mm tarafını kullandığından ve ` +
        `kareyi dış kenarlarından ölçtüğünden emin ol.`,
    };
  }

  if (Math.abs(factor - 1) < 0.002) {
    return {
      factor: 1,
      ok: true,
      message: "Ölçek doğru, düzeltmeye gerek yok.",
    };
  }

  return {
    factor,
    ok: true,
    message:
      `Ölçek %${((factor - 1) * 100).toFixed(1)} düzeltildi. ` +
      `PDF'i yeniden indirip aynı yazıcı ayarlarıyla bas.`,
  };
}
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
ODK_EOF_1

echo "==> packages/print/src/print.test.ts"
cat > packages/print/src/print.test.ts << 'ODK_EOF_2'
import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { PDFDocument } from "pdf-lib";
import { mmToPt } from "@odk/geometry";
import type { CardHolderParams } from "@odk/patterns";
import {
  BIFOLD_DEFAULTS,
  DEFAULT_PARAMS,
  buildInstructions,
  generateBifold,
  generateCardHolder,
} from "@odk/patterns";
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
import {
  packPages,
  packPieces,
  pieceToLayout,
  scaleFromMeasurement,
  STYLES,
} from "./layout.js";
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

describe("sayfa bazlı yerleştirme — hizalama gerektirmeyen çıktı", () => {
  const bifold = generateBifold(BIFOLD_DEFAULTS);

  it("bifold parçaları döndürülünce tek sayfaya sığıyor", () => {
    // ASIL KAZANÇ BU: döşeme olmadan hiçbir parça bölünmüyor, dolayısıyla
    // kullanıcının sayfa hizalama hatası ürünün ölçüsüne giremiyor.
    const layout = packPages(bifold.pieces);
    expect(layout.oversized).toHaveLength(0);
    expect(layout.rotatedCount).toBeGreaterThan(0);
  });

  it("her parça tam olarak bir kez yerleştiriliyor", () => {
    const layout = packPages(bifold.pieces);
    const placedIds = layout.pages.flatMap((p) => p.placed.map((x) => x.piece.id));
    expect(placedIds.sort()).toEqual(bifold.pieces.map((p) => p.id).sort());
  });

  it("yerleştirilen parçalar basılabilir alanı taşmıyor", () => {
    const area = printableArea(A4_PORTRAIT);
    for (const page of packPages(bifold.pieces).pages) {
      for (const p of page.placed) {
        expect(p.x).toBeGreaterThanOrEqual(-1e-9);
        expect(p.y).toBeGreaterThanOrEqual(-1e-9);
        expect(p.x + p.width).toBeLessThanOrEqual(area.width + 1e-9);
        expect(p.y + p.height).toBeLessThanOrEqual(area.height + 1e-9);
      }
    }
  });

  it("aynı sayfadaki parçalar üst üste binmiyor", () => {
    for (const page of packPages(bifold.pieces).pages) {
      for (let i = 0; i < page.placed.length; i++) {
        for (let j = i + 1; j < page.placed.length; j++) {
          const a = page.placed[i] as (typeof page.placed)[0];
          const b = page.placed[j] as (typeof page.placed)[0];
          const apart =
            a.x + a.width <= b.x + 1e-9 ||
            b.x + b.width <= a.x + 1e-9 ||
            a.y + a.height <= b.y + 1e-9 ||
            b.y + b.height <= a.y + 1e-9;
          expect(apart).toBe(true);
        }
      }
    }
  });

  it("döndürme kapatılırsa büyük parçalar döşemeye düşüyor", () => {
    const layout = packPages(bifold.pieces, A4_PORTRAIT, undefined, false);
    expect(layout.rotatedCount).toBe(0);
    expect(layout.oversized.length).toBeGreaterThan(0);
  });

  it("döndürülmüş parçada ölçüler takas ediliyor", () => {
    const layout = packPages(bifold.pieces);
    const outer = layout.pages
      .flatMap((p) => p.placed)
      .find((p) => p.piece.id === "outer");
    expect(outer?.rotated).toBe(true);
    expect(outer?.width).toBeCloseTo(outer?.piece.height as number, 9);
    expect(outer?.height).toBeCloseTo(outer?.piece.width as number, 9);
  });

  it("pieceToLayout döndürmeyi doğru uyguluyor", () => {
    // Yerel (0,0) köşesi, döndürülmüş parçada sol-ÜST köşeye gider.
    const placed = {
      piece: bifold.pieces[0] as (typeof bifold.pieces)[0],
      x: 10,
      y: 20,
      width: 50,
      height: 100,
      rotated: true,
    };
    expect(pieceToLayout(placed, { x: 0, y: 0 }, 0, 0)).toEqual({ x: 60, y: 20 });
    expect(pieceToLayout(placed, { x: 0, y: 50 }, 0, 0)).toEqual({ x: 10, y: 20 });
  });

  it("kartlıkta da hiç bölünme olmuyor", () => {
    const ch = generateCardHolder(DEFAULT_PARAMS);
    expect(packPages(ch.pieces).oversized).toHaveLength(0);
  });

  it("PDF üretilebiliyor ve sayfa sayısı makul", async () => {
    const bytes = await buildPatternPdf(bifold, FONTS, {
      params: BIFOLD_DEFAULTS,
    });
    const doc = await PDFDocument.load(bytes);
    // kapak + montaj + adımlar + desen sayfaları
    expect(doc.getPageCount()).toBeGreaterThanOrEqual(5);
    expect(doc.getPageCount()).toBeLessThan(12);
  });
});
ODK_EOF_2

echo "==> apps/web/src/pdf.ts"
cat > apps/web/src/pdf.ts << 'ODK_EOF_3'
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
  readonly allowRotation: boolean;
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
    allowRotation: options.allowRotation,
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
ODK_EOF_3

echo "==> apps/web/src/App.tsx"
cat > apps/web/src/App.tsx << 'ODK_EOF_4'
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
ODK_EOF_4

echo "==> Testler"
pnpm test

echo "==> Typecheck"
pnpm typecheck

echo "==> Arayuz derlemesi"
pnpm --filter @odk/web build

cat << 'ODK_DONE'

============================================================
SAYFA YERLESIMI — HIZALAMA KALKTI
============================================================

Bifold 2+2 (once/sonra):
  once:  A ve B iki sayfaya bolunuyordu, elle hizalama gerekiyordu
  sonra: S1 = A(90 derece) + B(90 derece), S2 = C + D, hic bolunme yok

Git:
  git add -A
  git commit -m "Doseme yerine sayfa bazli yerlestirme + 90 derece dondurme

SORUN
Doseme parcayi iki sayfaya boluyor ve kullanici sayfalari elle hizalayip
yapistiriyordu. Hizalama hatasi dogrudan urunun olcusune giriyor; mikron
hassasiyetle hesaplanmis bir kalibi yarim milimetrelik kaydirma anlamsiz
kiliyor.

COZUM
- packPages(): parcalar once sayfalara bin-pack ediliyor. Duz halde
  sigmayan parca 90 derece donduruluyor. Bifold'un 213.6x77.4mm dis
  kabugu donunce 77.4x213.6 oluyor ve 190x263mm alana rahat siginiyor.
- Yalnizca donduruldugu halde sigmayan parcalar doseme yoluna kaliyor.
- pieceToLayout(): dondurme TEK YERDE uygulaniyor. Kesim hatti, dikis
  hatti, delikler, kat cizgileri ve DAMAR OKU ayni donusumden geciyor.
  Oku sayfa koordinatinda sabit cizmek, dondurulmus parcada yanlis yon
  gosterirdi.
- Etiket yatay kaliyor; parca donse de yazinin donmesi okunabilirligi
  bozar.
- Kapak sayfasi hangi durumun gecerli oldugunu yaziyor: 'hizalama
  GEREKMIYOR' ya da hangi parcanin bolundugu.
- Arayuzde 'Dondur / Bol' secimi; dondurmeyi kapatmak damar kisiti sıkı
  olan kullanicilar icin anlamli.
- 311 test geciyor"

  git push
  vercel --prod
ODK_DONE
