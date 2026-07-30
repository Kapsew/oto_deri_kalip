/**
 * Birim sistemi.
 *
 * KURAL: Motorun içinde her uzunluk milimetredir. Inch, point veya piksel
 * yalnızca çıktı katmanında (PDF/SVG) görülür. Bu dosyanın dışında
 * dönüşüm yapılmaz.
 */

/** Milimetre. Motorun tek uzunluk birimi. */
export type Mm = number;

/**
 * Karşılaştırma toleransı: 1 mikron.
 *
 * Neden 1e-3: elle kesim hedef kitlemizde gerçek hata payı ~0.3-0.5mm.
 * Mikron altı fark fiziksel olarak anlamsız, ama float birikmesini
 * (0.1+0.2 !== 0.3) yakalayacak kadar da sıkı.
 */
export const EPS: Mm = 1e-3;

/** a ile b pratikte eşit mi? */
export function eq(a: Mm, b: Mm, eps: Mm = EPS): boolean {
  return Math.abs(a - b) <= eps;
}

/** a, b'den anlamlı ölçüde küçük mü? */
export function lt(a: Mm, b: Mm, eps: Mm = EPS): boolean {
  return a < b - eps;
}

/** a, b'den anlamlı ölçüde büyük mü? */
export function gt(a: Mm, b: Mm, eps: Mm = EPS): boolean {
  return a > b + eps;
}

export function lte(a: Mm, b: Mm, eps: Mm = EPS): boolean {
  return !gt(a, b, eps);
}

export function gte(a: Mm, b: Mm, eps: Mm = EPS): boolean {
  return !lt(a, b, eps);
}

/** Sıfıra pratikte eşit mi? */
export function isZero(a: Mm, eps: Mm = EPS): boolean {
  return Math.abs(a) <= eps;
}

export function clamp(v: number, min: number, max: number): number {
  return v < min ? min : v > max ? max : v;
}

/** Mikron hassasiyetine yuvarla. Kayan nokta çöpünü temizlemek için. */
export function snap(v: Mm): Mm {
  return Math.round(v * 1000) / 1000;
}

// --- Baskı birimleri -------------------------------------------------------
// PDF kullanıcı uzayı 1/72 inch = 1 point. pdf-lib bu birimi bekler.

const MM_PER_INCH = 25.4;
const PT_PER_INCH = 72;

export function mmToPt(mm: Mm): number {
  return (mm / MM_PER_INCH) * PT_PER_INCH;
}

export function ptToMm(pt: number): Mm {
  return (pt / PT_PER_INCH) * MM_PER_INCH;
}

export function mmToInch(mm: Mm): number {
  return mm / MM_PER_INCH;
}

export function inchToMm(inch: number): Mm {
  return inch * MM_PER_INCH;
}

// --- Sabitler --------------------------------------------------------------

/** ISO 216 A4, portre. Baskı katmanının referansı. */
export const A4: { readonly width: Mm; readonly height: Mm } = {
  width: 210,
  height: 297,
};

/** ISO/IEC 7810 ID-1 (kredi kartı). Kart yuvası hesaplarının temeli. */
export const CARD_ID1: {
  readonly width: Mm;
  readonly height: Mm;
  readonly thickness: Mm;
  readonly cornerRadius: Mm;
} = {
  width: 85.6,
  height: 53.98,
  thickness: 0.76,
  cornerRadius: 3.18,
};

/**
 * Piyasadaki pricking iron adımları (mm).
 *
 * Dikiş dağıtıcısı serbest adım üretemez; kullanıcının elindeki takım
 * bu değerlerden biridir. Segment uzunluğu tam bölünmediğinde adımı
 * değiştirmek yerine sapmayı tolere ederiz.
 */
export const IRON_PITCHES: readonly Mm[] = [2.7, 3.0, 3.38, 3.85, 4.0, 5.0];
