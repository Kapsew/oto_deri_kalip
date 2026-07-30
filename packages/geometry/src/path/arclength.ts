import type { Mm } from "../units.js";
import { EPS, clamp } from "../units.js";
import type { Vec } from "../vec.js";
import { distance, lerp, normalize, sub, dot } from "../vec.js";
import type { Polyline } from "./path.js";

/**
 * Yay uzunluğuna göre parametrize edilmiş yol.
 *
 * NEDEN GEREKLİ: dikiş delikleri eşit ARALIKLARLA yerleşir, eşit
 * PARAMETREYLE değil. Bezier'in t parametresi eğri boyunca düzgün
 * ilerlemez; t=0.5 eğrinin ortası değildir. Delik dağıtımı için
 * mesafeden noktaya gidebilmek zorunludur.
 */
export interface ArcLengthTable {
  readonly points: Polyline;
  /** cumulative[i] = points[0]'dan points[i]'ye kadar yol uzunluğu. */
  readonly cumulative: readonly Mm[];
  readonly totalLength: Mm;
  readonly closed: boolean;
}

export function buildArcLengthTable(
  poly: Polyline,
  closed: boolean,
): ArcLengthTable {
  const cumulative: Mm[] = [0];
  for (let i = 1; i < poly.length; i++) {
    const prev = cumulative[i - 1] as Mm;
    cumulative.push(prev + distance(poly[i - 1] as Vec, poly[i] as Vec));
  }
  if (closed && poly.length > 1) {
    const prev = cumulative.at(-1) as Mm;
    cumulative.push(prev + distance(poly.at(-1) as Vec, poly[0] as Vec));
  }
  return {
    points: poly,
    cumulative,
    totalLength: cumulative.at(-1) ?? 0,
    closed,
  };
}

/** Mesafeyi sınırlar içine getirir. Kapalı yolda sarar, açıkta kırpar. */
function normalizeDistance(table: ArcLengthTable, d: Mm): Mm {
  const total = table.totalLength;
  if (total <= EPS) return 0;
  if (!table.closed) return clamp(d, 0, total);
  const m = d % total;
  return m < 0 ? m + total : m;
}

/**
 * Yol başlangıcından d mm ilerideki nokta.
 *
 * İkili arama kullanır: O(log n). Bir kenara 200 delik dağıtırken
 * lineer tarama fark ettirir.
 */
export function pointAtDistance(table: ArcLengthTable, d: Mm): Vec {
  const first = table.points[0];
  if (first === undefined) return { x: 0, y: 0 };
  if (table.points.length === 1) return first;

  const target = normalizeDistance(table, d);
  const cum = table.cumulative;

  let lo = 0;
  let hi = cum.length - 1;
  while (lo < hi - 1) {
    const mid = (lo + hi) >> 1;
    if ((cum[mid] as Mm) <= target) lo = mid;
    else hi = mid;
  }

  const segStart = cum[lo] as Mm;
  const segEnd = cum[lo + 1] as Mm;
  const segLen = segEnd - segStart;

  const a = table.points[lo] as Vec;
  const b = pointAtIndex(table, lo + 1);

  if (segLen <= EPS) return a;
  return lerp(a, b, (target - segStart) / segLen);
}

/** Kapalı yolda son+1 indeksi ilk noktaya sarar. */
function pointAtIndex(table: ArcLengthTable, i: number): Vec {
  const p = table.points[i];
  if (p !== undefined) return p;
  return table.points[0] as Vec;
}

/** d mesafesindeki teğet (ilerleme yönü, birim vektör). */
export function tangentAtDistance(table: ArcLengthTable, d: Mm): Vec {
  const h = Math.max(EPS * 10, table.totalLength * 1e-4);
  const a = pointAtDistance(table, d - h);
  const b = pointAtDistance(table, d + h);
  return normalize(sub(b, a));
}

/**
 * Bir köşe (dikiş çapası).
 *
 * Dikiş dağıtıcısı köşelere delik koymak ZORUNDA: köşede delik yoksa
 * iplik dönüşü bozulur ve kenar buruşur. Bu yüzden köşeler segment
 * sınırı olarak işaretlenir ve delik sayısı her segment için ayrı
 * yuvarlanır.
 */
export interface Corner {
  /** points dizisindeki indeks. */
  readonly index: number;
  /** Yol başından bu köşeye kadarki mesafe. */
  readonly distance: Mm;
  /** Yön değişimi (radyan). Pozitif = sola dönüş. */
  readonly turn: number;
}

/**
 * Belirgin köşeleri bulur.
 *
 * minAngleDeg neden 25°: düzleştirilmiş bezier'de ardışık noktalar
 * arasında 1-5°'lik dönüşler olur; bunlar köşe değil. 25° üstü, kalıpta
 * gerçekten kırılma demektir.
 */
export function findCorners(
  table: ArcLengthTable,
  minAngleDeg = 25,
): Corner[] {
  const pts = table.points;
  const n = pts.length;
  if (n < 3) return [];

  const minCos = Math.cos((minAngleDeg * Math.PI) / 180);
  const corners: Corner[] = [];
  const startIdx = table.closed ? 0 : 1;
  const endIdx = table.closed ? n - 1 : n - 2;

  for (let i = startIdx; i <= endIdx; i++) {
    const prev = pts[(i - 1 + n) % n] as Vec;
    const cur = pts[i] as Vec;
    const next = pts[(i + 1) % n] as Vec;

    const inDir = normalize(sub(cur, prev));
    const outDir = normalize(sub(next, cur));
    const c = clamp(dot(inDir, outDir), -1, 1);

    if (c < minCos) {
      corners.push({
        index: i,
        distance: table.cumulative[i] as Mm,
        turn: Math.atan2(
          inDir.x * outDir.y - inDir.y * outDir.x,
          c,
        ),
      });
    }
  }
  return corners;
}

/**
 * Yolu köşelerden bölerek dikiş segmentlerine ayırır.
 * Her segment kendi delik sayısını bağımsız hesaplayacak.
 */
export interface Span {
  readonly startDistance: Mm;
  readonly endDistance: Mm;
  readonly length: Mm;
}

export function spansBetweenCorners(
  table: ArcLengthTable,
  corners: readonly Corner[],
): Span[] {
  const total = table.totalLength;
  if (total <= EPS) return [];

  const marks = corners.map((c) => c.distance);

  if (marks.length === 0) {
    return [{ startDistance: 0, endDistance: total, length: total }];
  }

  const spans: Span[] = [];

  if (table.closed) {
    for (let i = 0; i < marks.length; i++) {
      const a = marks[i] as Mm;
      const b = (marks[(i + 1) % marks.length] as Mm) + (i === marks.length - 1 ? total : 0);
      const len = b - a;
      if (len > EPS) {
        spans.push({ startDistance: a, endDistance: b, length: len });
      }
    }
  } else {
    const bounds = [0, ...marks, total];
    for (let i = 0; i < bounds.length - 1; i++) {
      const a = bounds[i] as Mm;
      const b = bounds[i + 1] as Mm;
      if (b - a > EPS) {
        spans.push({ startDistance: a, endDistance: b, length: b - a });
      }
    }
  }

  return spans;
}
