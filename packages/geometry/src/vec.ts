import type { Mm } from "./units.js";
import { eq, isZero } from "./units.js";

/**
 * Düzlemde bir nokta / vektör. Birim mm.
 *
 * Koordinat sistemi: x sağa, y YUKARI (matematiksel). SVG ve PDF farklı
 * yönler kullanır; çevirme işi çıktı katmanının sorumluluğunda.
 */
export interface Vec {
  readonly x: Mm;
  readonly y: Mm;
}

export function vec(x: Mm, y: Mm): Vec {
  return { x, y };
}

export const ORIGIN: Vec = { x: 0, y: 0 };

export function add(a: Vec, b: Vec): Vec {
  return { x: a.x + b.x, y: a.y + b.y };
}

export function sub(a: Vec, b: Vec): Vec {
  return { x: a.x - b.x, y: a.y - b.y };
}

export function scale(a: Vec, k: number): Vec {
  return { x: a.x * k, y: a.y * k };
}

export function neg(a: Vec): Vec {
  return { x: -a.x, y: -a.y };
}

export function dot(a: Vec, b: Vec): number {
  return a.x * b.x + a.y * b.y;
}

/** 2D çapraz çarpımın skaler karşılığı. İşareti dönüş yönünü verir. */
export function cross(a: Vec, b: Vec): number {
  return a.x * b.y - a.y * b.x;
}

export function length(a: Vec): Mm {
  return Math.hypot(a.x, a.y);
}

export function distance(a: Vec, b: Vec): Mm {
  return Math.hypot(b.x - a.x, b.y - a.y);
}

/** Birim vektör. Sıfır vektörde sıfır döner (patlamaz). */
export function normalize(a: Vec): Vec {
  const len = length(a);
  if (isZero(len)) return ORIGIN;
  return { x: a.x / len, y: a.y / len };
}

export function lerp(a: Vec, b: Vec, t: number): Vec {
  return { x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t };
}

/** Saat yönünün tersine 90 derece. Kenar normali üretmek için. */
export function perpCCW(a: Vec): Vec {
  return { x: -a.y, y: a.x };
}

/** Saat yönünde 90 derece. */
export function perpCW(a: Vec): Vec {
  return { x: a.y, y: -a.x };
}

export function rotate(a: Vec, radians: number): Vec {
  const c = Math.cos(radians);
  const s = Math.sin(radians);
  return { x: a.x * c - a.y * s, y: a.x * s + a.y * c };
}

export function vecEq(a: Vec, b: Vec, eps?: Mm): boolean {
  return eq(a.x, b.x, eps) && eq(a.y, b.y, eps);
}

/**
 * p noktasının a-b doğru parçasına en kısa mesafesi.
 * Kalem payı ve minimum kenar mesafesi kontrollerinde kullanılır.
 */
export function distanceToSegment(p: Vec, a: Vec, b: Vec): Mm {
  const ab = sub(b, a);
  const lenSq = dot(ab, ab);
  if (isZero(lenSq)) return distance(p, a);
  let t = dot(sub(p, a), ab) / lenSq;
  t = t < 0 ? 0 : t > 1 ? 1 : t;
  return distance(p, add(a, scale(ab, t)));
}
