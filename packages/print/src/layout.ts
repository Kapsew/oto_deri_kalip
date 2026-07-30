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
