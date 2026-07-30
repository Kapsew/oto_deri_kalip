import type { Mm } from "../units.js";
import type { Vec } from "../vec.js";
import { distanceToSegment, sub, normalize, lerp } from "../vec.js";

/**
 * Kübik bezier. Kalıp kenarlarındaki yuvarlatmalar ve organik hatlar için.
 *
 * Motorun geri kalanı yalnızca poligonlarla çalışır (Clipper2 de öyle);
 * bezier bu dosyada düzleştirilir ve bir daha görünmez.
 */
export interface Cubic {
  readonly p0: Vec;
  readonly c1: Vec;
  readonly c2: Vec;
  readonly p1: Vec;
}

/**
 * Varsayılan düzleştirme toleransı.
 *
 * 0.05mm: yazıcı çözünürlüğünün (600dpi ≈ 0.042mm) altında kalır, yani
 * düzleştirme hatası baskıda görünmez. Elle kesim hata payının ~1/10'u.
 */
export const FLATTEN_TOLERANCE: Mm = 0.05;

/** t ∈ [0,1] için eğri üstündeki nokta (de Casteljau). */
export function cubicAt(c: Cubic, t: number): Vec {
  const a = lerp(c.p0, c.c1, t);
  const b = lerp(c.c1, c.c2, t);
  const d = lerp(c.c2, c.p1, t);
  const e = lerp(a, b, t);
  const f = lerp(b, d, t);
  return lerp(e, f, t);
}

/** t noktasındaki teğet (birim vektör). Dikiş normali için gerekli. */
export function cubicTangent(c: Cubic, t: number): Vec {
  const mt = 1 - t;
  const w0 = 3 * mt * mt;
  const w1 = 6 * mt * t;
  const w2 = 3 * t * t;
  const d = {
    x: w0 * (c.c1.x - c.p0.x) + w1 * (c.c2.x - c.c1.x) + w2 * (c.p1.x - c.c2.x),
    y: w0 * (c.c1.y - c.p0.y) + w1 * (c.c2.y - c.c1.y) + w2 * (c.p1.y - c.c2.y),
  };
  return normalize(d);
}

/** t'de ikiye böl (de Casteljau). Adaptif düzleştirmenin temeli. */
export function splitCubic(c: Cubic, t: number): [Cubic, Cubic] {
  const a = lerp(c.p0, c.c1, t);
  const b = lerp(c.c1, c.c2, t);
  const d = lerp(c.c2, c.p1, t);
  const e = lerp(a, b, t);
  const f = lerp(b, d, t);
  const g = lerp(e, f, t);
  return [
    { p0: c.p0, c1: a, c2: e, p1: g },
    { p0: g, c1: f, c2: d, p1: c.p1 },
  ];
}

/**
 * Eğrinin p0-p1 kirişinden ne kadar saptığı.
 * Kontrol noktalarının kirişe uzaklığı, gerçek sapmanın üst sınırıdır.
 */
function chordDeviation(c: Cubic): Mm {
  return Math.max(
    distanceToSegment(c.c1, c.p0, c.p1),
    distanceToSegment(c.c2, c.p0, c.p1),
  );
}

/**
 * Eğriyi tolerans içinde kalan bir nokta dizisine çevirir.
 *
 * Dönen dizi p0'ı İÇERMEZ; yalnızca ara noktalar ve p1'i verir. Böylece
 * ardışık segmentler birleştirilirken nokta tekrarı olmaz.
 */
export function flattenCubic(
  c: Cubic,
  tolerance: Mm = FLATTEN_TOLERANCE,
  maxDepth = 18,
): Vec[] {
  const out: Vec[] = [];
  recurse(c, tolerance, maxDepth, out);
  out.push(c.p1);
  return out;
}

function recurse(c: Cubic, tol: Mm, depth: number, out: Vec[]): void {
  if (depth <= 0 || chordDeviation(c) <= tol) return;
  const [left, right] = splitCubic(c, 0.5);
  recurse(left, tol, depth - 1, out);
  out.push(left.p1);
  recurse(right, tol, depth - 1, out);
}

/** Düz bir çizgiden ayırt edilemeyecek kadar düz mü? */
export function isCubicFlat(c: Cubic, tolerance: Mm = FLATTEN_TOLERANCE): boolean {
  return chordDeviation(c) <= tolerance;
}

/** Kabaca eğri uzunluğu (yalnızca hızlı tahmin gerektiğinde). */
export function cubicApproxLength(c: Cubic, samples = 16): Mm {
  let total = 0;
  let prev = c.p0;
  for (let i = 1; i <= samples; i++) {
    const cur = cubicAt(c, i / samples);
    total += Math.hypot(cur.x - prev.x, cur.y - prev.y);
    prev = cur;
  }
  return total;
}

/** İki noktayı birleştiren, kontrol noktaları kiriş üstünde olan kübik. */
export function cubicFromLine(p0: Vec, p1: Vec): Cubic {
  const d = sub(p1, p0);
  return {
    p0,
    c1: { x: p0.x + d.x / 3, y: p0.y + d.y / 3 },
    c2: { x: p0.x + (2 * d.x) / 3, y: p0.y + (2 * d.y) / 3 },
    p1,
  };
}
