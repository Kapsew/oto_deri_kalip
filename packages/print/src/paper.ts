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
