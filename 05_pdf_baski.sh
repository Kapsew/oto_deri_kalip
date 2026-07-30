#!/usr/bin/env bash
#
# Faz 2 — Baski katmani (1:1 PDF, kalibrasyon karesi, A4 doseme)
#
# Kullanim:
#   chmod +x 05_pdf_baski.sh
#   ./05_pdf_baski.sh
#
# Repo kokunde calistirilmalidir. Idempotent.

set -euo pipefail

if [ ! -f "pnpm-workspace.yaml" ] || [ ! -d "apps/web" ]; then
  echo "HATA: Bu script repo kokunde calistirilmali." >&2
  echo "       Once 04_dikis_ve_arayuz.sh calistirilmis olmali." >&2
  exit 1
fi

if ! command -v pnpm > /dev/null 2>&1; then
  echo "HATA: pnpm bulunamadi. Kurulum: npm i -g pnpm@9" >&2
  exit 1
fi

echo "==> Dizinler"
mkdir -p packages/print/src apps/web/src

echo "==> package.json"
cat > package.json << 'ODK_EOF_0'
{
  "name": "oto-deri-kalip",
  "private": true,
  "version": "0.0.1",
  "packageManager": "pnpm@9.15.9",
  "scripts": {
    "build": "turbo run build",
    "test": "turbo run test",
    "typecheck": "turbo run typecheck",
    "test:geometry": "pnpm --filter @odk/geometry test"
  },
  "devDependencies": {
    "@types/node": "^22",
    "turbo": "^2.3.3",
    "typescript": "^5.7.2",
    "vitest": "^2.1.8"
  },
  "engines": {
    "node": ">=20"
  }
}
ODK_EOF_0

echo "==> packages/print/package.json"
cat > packages/print/package.json << 'ODK_EOF_1'
{
  "name": "@odk/print",
  "version": "0.0.1",
  "private": true,
  "type": "module",
  "main": "./src/index.ts",
  "types": "./src/index.ts",
  "exports": {
    ".": "./src/index.ts"
  },
  "scripts": {
    "test": "vitest run",
    "typecheck": "tsc --noEmit"
  },
  "dependencies": {
    "@odk/geometry": "workspace:*",
    "@odk/patterns": "workspace:*",
    "@pdf-lib/fontkit": "^1.1.1",
    "pdf-lib": "^1.17.1"
  },
  "devDependencies": {
    "@expo-google-fonts/ibm-plex-sans": "^0.4.1",
    "typescript": "^5.7.2",
    "vitest": "^2.1.8",
    "@expo-google-fonts/jetbrains-mono": "^0.4.1"
  }
}
ODK_EOF_1

echo "==> packages/print/tsconfig.json"
cat > packages/print/tsconfig.json << 'ODK_EOF_2'
{
  "extends": "../../tsconfig.base.json",
  "compilerOptions": {
    "rootDir": "src",
    "outDir": "dist",
    "types": ["vitest/globals", "node"]
  },
  "include": ["src/**/*.ts"]
}
ODK_EOF_2

echo "==> packages/print/vitest.config.ts"
cat > packages/print/vitest.config.ts << 'ODK_EOF_3'
import { defineConfig } from "vitest/config";

export default defineConfig({
  test: { globals: true, include: ["src/**/*.test.ts"] },
});
ODK_EOF_3

echo "==> packages/print/src/paper.ts"
cat > packages/print/src/paper.ts << 'ODK_EOF_4'
import type { Mm } from "@odk/geometry";

/**
 * KAĞIT VE DÖŞEME (TILING)
 *
 * Hedef kitlemiz A4'e basıp elle kesiyor. Bu katmandaki hataların
 * kalıp matematiğindeki hatalardan daha pahalı olduğunu Faz 1'de
 * tespit ettik: %2'lik bir yazıcı ölçek hatası, mikron hassasiyetle
 * hesaplanmış bir kalıbı çöpe atar.
 */

export interface PaperSpec {
  readonly name: string;
  readonly width: Mm;
  readonly height: Mm;
  /**
   * Ev yazıcılarının basamadığı kenar bandı.
   *
   * 10mm güvenli varsayım: çoğu inkjet 3–6mm, lazerler 4–5mm istiyor,
   * ama kullanıcının yazıcısını bilmiyoruz ve kalıbın kenarının
   * kırpılması sessiz bir hata olurdu.
   */
  readonly printerMargin: Mm;
  /** Altta ölçek çubuğu ve sayfa kodu için ayrılan şerit. */
  readonly footerHeight: Mm;
}

export const A4_PORTRAIT: PaperSpec = {
  name: "A4",
  width: 210,
  height: 297,
  printerMargin: 10,
  footerHeight: 14,
};

export const LETTER_PORTRAIT: PaperSpec = {
  name: "Letter",
  width: 215.9,
  height: 279.4,
  printerMargin: 10,
  footerHeight: 14,
};

export interface PrintableArea {
  readonly width: Mm;
  readonly height: Mm;
  /** Sayfa sol-alt köşesinden içeriğin başladığı nokta. */
  readonly originX: Mm;
  readonly originY: Mm;
}

export function printableArea(paper: PaperSpec): PrintableArea {
  return {
    width: paper.width - 2 * paper.printerMargin,
    height: paper.height - 2 * paper.printerMargin - paper.footerHeight,
    originX: paper.printerMargin,
    originY: paper.printerMargin + paper.footerHeight,
  };
}

/**
 * Komşu sayfaların bindirme payı.
 *
 * 10mm sabit; yol haritasında "%10" yazıyordu ama oran kullanmak
 * yanlış olurdu: bindirmenin işlevi hizalama işaretlerine ve yapıştırma
 * şeridine yer açmak, sayfa boyutuyla orantılı olması gerekmiyor.
 * 10mm iki hizalama haçı ve rahat bir yapıştırma bandı için yeterli.
 */
export const TILE_OVERLAP: Mm = 10;

/** Kalibrasyon karesinin nominal kenarı. */
export const CALIBRATION_SQUARE: Mm = 50;

export interface TileGrid {
  readonly cols: number;
  readonly rows: number;
  readonly tileWidth: Mm;
  readonly tileHeight: Mm;
  readonly stepX: Mm;
  readonly stepY: Mm;
  readonly overlap: Mm;
  readonly sheetWidth: Mm;
  readonly sheetHeight: Mm;
}

/**
 * Sanal tabakayı sayfalara böler.
 *
 * Adım = basılabilir alan − bindirme. Böylece n. sayfanın sağ kenarındaki
 * `overlap` şeridi, (n+1). sayfanın sol kenarında tekrar basılır ve
 * kullanıcı üst üste getirerek hizalayabilir.
 */
export function planTiles(
  sheetWidth: Mm,
  sheetHeight: Mm,
  paper: PaperSpec = A4_PORTRAIT,
  overlap: Mm = TILE_OVERLAP,
): TileGrid {
  const area = printableArea(paper);
  const stepX = area.width - overlap;
  const stepY = area.height - overlap;

  if (stepX <= 0 || stepY <= 0) {
    throw new Error(
      "planTiles: bindirme payı basılabilir alandan büyük; sayfa asla ilerlemez.",
    );
  }

  const cols = Math.max(1, Math.ceil((sheetWidth - overlap) / stepX));
  const rows = Math.max(1, Math.ceil((sheetHeight - overlap) / stepY));

  return {
    cols,
    rows,
    tileWidth: area.width,
    tileHeight: area.height,
    stepX,
    stepY,
    overlap,
    sheetWidth,
    sheetHeight,
  };
}

/**
 * Bir döşemenin sanal tabakadaki sol-alt köşesi.
 *
 * DÜZENLİ IZGARA KORUNUR: son satır/sütun tabakanın kenarına
 * hizalanmaz. Hizalamak boş alanı azaltırdı ama döşeme adımını
 * bozardı; köşe haçları ancak tüm sayfalar aynı adımda olduğunda
 * çakışır. Son sayfada boşluk kalması, hizalamanın bozulmasından
 * çok daha ucuz bir bedel.
 *
 * Satırlar YUKARIDAN aşağı numaralanır (kullanıcı sayfaları okuma
 * sırasına göre dizer) ama tabaka koordinatları aşağıdan yukarı.
 */
export function tileOrigin(
  grid: TileGrid,
  col: number,
  row: number,
): { readonly x: Mm; readonly y: Mm } {
  const x = col * grid.stepX;
  const topY = grid.sheetHeight - row * grid.stepY;
  return { x, y: topY - grid.tileHeight };
}

/**
 * Sayfa kodu: sütun harfi + satır numarası (A1, A2, B1...).
 * Kullanıcı sayfaları bu koda göre diziyor.
 */
export function tileCode(col: number, row: number): string {
  let n = col;
  let letters = "";
  do {
    letters = String.fromCharCode(65 + (n % 26)) + letters;
    n = Math.floor(n / 26) - 1;
  } while (n >= 0);
  return `${letters}${row + 1}`;
}

export function tileCount(grid: TileGrid): number {
  return grid.cols * grid.rows;
}
ODK_EOF_4

echo "==> packages/print/src/layout.ts"
cat > packages/print/src/layout.ts << 'ODK_EOF_5'
import type { Mm } from "@odk/geometry";
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
  /** Tabaka koordinatında sol-alt köşe. */
  readonly x: Mm;
  readonly y: Mm;
  readonly width: Mm;
  readonly height: Mm;
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
  }));

  return { placed, width: sheetWidth, height };
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
ODK_EOF_5

echo "==> packages/print/src/pdf.ts"
cat > packages/print/src/pdf.ts << 'ODK_EOF_6'
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
   * Varsayılan KAPALI. Elle çalışan kullanıcı delikleri pricking iron
   * ile kendisi yürüyor; yüzlerce nokta basmak hem mürekkep israfı hem
   * de yanıltıcı — kağıda basılmış nokta ile ironun gerçek adımı
   * arasındaki fark kullanıcıyı yanlış yönlendirir. Bunun yerine köşe
   * çapaları ve kenar başına delik sayısı veriliyor.
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
  text(page, "parça", left, y, 8, ctx.mono, 0.5);
  text(page, "adet", left + 55, y, 8, ctx.mono, 0.5);
  text(page, "ölçü (mm)", left + 70, y, 8, ctx.mono, 0.5);
  text(page, "deri", left + 110, y, 8, ctx.mono, 0.5);
  y -= 1.5;
  line(page, { x: left, y }, { x: left + area.width, y }, STYLES.guide, 1);
  y -= 4.5;

  for (const p of pattern.pieces) {
    text(page, p.name, left, y, 9, ctx.body);
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
    drawPiece(ctx, page, placed, tx, options.printAllHoles ?? false);
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
    `${piece.name}  ×${piece.quantity}  ${piece.width.toFixed(1)}×${piece.height.toFixed(1)}mm  ${piece.leatherThickness.toFixed(1)}mm deri`,
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
ODK_EOF_6

echo "==> packages/print/src/index.ts"
cat > packages/print/src/index.ts << 'ODK_EOF_7'
/**
 * @odk/print — 1:1 basılabilir PDF üretimi.
 *
 * Platform bağımsız: font baytları dışarıdan verilir, dosya sistemi ya
 * da tarayıcı API'si kullanılmaz. Böylece hem Node testlerinde hem
 * tarayıcıda aynı kod çalışır.
 */

export * from "./paper.js";
export * from "./layout.js";
export * from "./pdf.js";
ODK_EOF_7

echo "==> packages/print/src/print.test.ts"
cat > packages/print/src/print.test.ts << 'ODK_EOF_8'
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

  it("kapak + desen sayfaları", async () => {
    const bytes = await buildPatternPdf(pattern, FONTS);
    const doc = await PDFDocument.load(bytes);
    const layout = packPieces(pattern.pieces);
    const grid = planTiles(layout.width, layout.height);
    expect(doc.getPageCount()).toBe(1 + tileCount(grid));
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
ODK_EOF_8

echo "==> apps/web/package.json"
cat > apps/web/package.json << 'ODK_EOF_9'
{
  "name": "@odk/web",
  "version": "0.0.1",
  "private": true,
  "type": "module",
  "scripts": {
    "dev": "vite",
    "build": "vite build",
    "preview": "vite preview",
    "typecheck": "tsc --noEmit"
  },
  "dependencies": {
    "@odk/geometry": "workspace:*",
    "@odk/patterns": "workspace:*",
    "react": "^18.3.1",
    "react-dom": "^18.3.1",
    "@odk/print": "workspace:*",
    "@expo-google-fonts/ibm-plex-sans": "^0.4.1",
    "@expo-google-fonts/jetbrains-mono": "^0.4.1"
  },
  "devDependencies": {
    "@types/react": "^18.3.12",
    "@types/react-dom": "^18.3.1",
    "@vitejs/plugin-react": "^4.3.4",
    "typescript": "^5.7.2",
    "vite": "^5.4.11"
  }
}
ODK_EOF_9

echo "==> apps/web/index.html"
cat > apps/web/index.html << 'ODK_EOF_10'
<!doctype html>
<html lang="tr">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>Deri Kalıp Motoru</title>
    <meta name="description" content="El yapımı deri ürünler için ölçülü, dikiş izli, A4'e 1:1 basılabilir kalıp üretir." />
    <link rel="preconnect" href="https://fonts.googleapis.com" />
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin />
    <link
      href="https://fonts.googleapis.com/css2?family=IBM+Plex+Sans+Condensed:wght@400;500;600;700&family=JetBrains+Mono:wght@400;500;600&display=swap"
      rel="stylesheet"
    />
  </head>
  <body>
    <div id="root"></div>
    <script type="module" src="/src/main.tsx"></script>
  </body>
</html>
ODK_EOF_10

echo "==> apps/web/src/pdf.ts"
cat > apps/web/src/pdf.ts << 'ODK_EOF_11'
import type { PatternResult } from "@odk/patterns";
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
ODK_EOF_11

echo "==> apps/web/src/App.tsx"
cat > apps/web/src/App.tsx << 'ODK_EOF_12'
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
  printAllHoles: false,
  measured: "50",
  scaleFactor: 1,
  note: "",
  noteOk: true,
  busy: false,
};

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
            hint="Delikleri iron ile kendin yürüyorsan köşe çapaları yeterli; kapak sayfasında kenar başına sayı var."
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
ODK_EOF_12

echo "==> apps/web/src/styles.css"
cat > apps/web/src/styles.css << 'ODK_EOF_13'
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
ODK_EOF_13

echo "==> Bagimliliklar"
pnpm install

echo "==> Testler"
pnpm test

echo "==> Typecheck"
pnpm typecheck

echo "==> Arayuz derlemesi"
pnpm --filter @odk/web build

cat << 'ODK_DONE'

============================================================
FAZ 2 TAMAM — Basilabilir PDF
============================================================

Yerelde:
  pnpm --filter @odk/web dev
  # http://localhost:5173 -> sag rayda "Baski" bolumu -> PDF indir

ILK BASKI TESTI (sirasiyla):
  1. PDF indir, yazicida ac
  2. Olcek %100 / Actual size, "Sayfaya sigdir" KAPALI
  3. Kapak sayfasindaki 50mm kareyi cetvelle olc
  4. 50mm degilse olctugun degeri "Olctugun kare" alanina gir, Uygula
  5. PDF'i yeniden indir ve tekrar bas
  6. Kareyi tekrar olc - 50mm olmali

Git:

  git add -A
  git commit -m "Faz 2: basilabilir PDF katmani

- @odk/print: platform bagimsiz, font baytlari disaridan verilir
- 1:1 cikti; birim donusumu yalnizca pdf-lib sinirinda (mmToPt)
- kapak sayfasi: 50mm kalibrasyon karesi, baski ayari uyarisi,
  parca listesi, dikis plani, olculer, tanilamalar
- A4 doseme: 10mm bindirme, kose hizalama haclari, sayfa kodlari
- cizgiler renkle degil desenle ayrisir (siyah-beyaz yazici icin)
- her sayfada 50mm olcek cubugu
- kalibrasyon: olculen kareden olcek katsayisi, %10 disi reddedilir
- FONT: JetBrains Mono secildi; IBM Plex Mono TTF fontkit ile BOSLUK
  karakterinde patliyor (test ile sabitlendi)
- yerlesim: her parcanin ustunde etiket icin 8mm ayrildi, ilk uretilen
  PDF'te en usttteki etiket kirpiliyordu
- PDF katmani dinamik import: ana bundle 1.29MB -> 270KB
- 244 test geciyor"

  git push
  vercel --prod

Sonraki: Faz 3 modul sistemi (BillPocket, CoinPocket) ya da
Faz 6 fiziksel dogrulama - hangisi once, ilk baski sonucuna bagli.
ODK_DONE
