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
