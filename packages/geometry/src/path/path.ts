import type { Mm } from "../units.js";
import { EPS } from "../units.js";
import type { Vec } from "../vec.js";
import { vecEq, distance, cross, sub } from "../vec.js";
import type { Cubic } from "./bezier.js";
import { flattenCubic, FLATTEN_TOLERANCE } from "./bezier.js";

/** Doğru parçası. `to` bitiş noktası; başlangıç önceki segmentten gelir. */
export interface LineSegment {
  readonly kind: "line";
  readonly to: Vec;
}

/** Kübik bezier parçası. */
export interface CubicSegment {
  readonly kind: "cubic";
  readonly c1: Vec;
  readonly c2: Vec;
  readonly to: Vec;
}

export type Segment = LineSegment | CubicSegment;

/**
 * Tek parçalı yol.
 *
 * `start` + segment zinciri şeklinde tutulur; her segmentin başlangıcı
 * bir öncekinin bitişidir. Bu gösterim, kalıp parçalarının kenarlarını
 * sırayla gezmeyi (dikiş dağıtımı için şart) doğal kılar.
 */
export interface Path {
  readonly start: Vec;
  readonly segments: readonly Segment[];
  /** Kapalı yol: son nokta start'a bağlanır. Kalıp parçaları her zaman kapalıdır. */
  readonly closed: boolean;
}

/** Düzleştirilmiş yol. Kapalıysa ilk nokta tekrar EDİLMEZ. */
export type Polyline = readonly Vec[];

export class PathBuilder {
  private startPoint: Vec | undefined;
  private readonly segs: Segment[] = [];
  private cursor: Vec | undefined;

  moveTo(p: Vec): this {
    if (this.startPoint !== undefined) {
      throw new Error("PathBuilder: moveTo yalnızca bir kez çağrılabilir");
    }
    this.startPoint = p;
    this.cursor = p;
    return this;
  }

  lineTo(p: Vec): this {
    this.requireStart();
    this.segs.push({ kind: "line", to: p });
    this.cursor = p;
    return this;
  }

  cubicTo(c1: Vec, c2: Vec, to: Vec): this {
    this.requireStart();
    this.segs.push({ kind: "cubic", c1, c2, to });
    this.cursor = to;
    return this;
  }

  /** Birden fazla noktayı sırayla doğru parçalarıyla bağlar. */
  polylineTo(points: readonly Vec[]): this {
    for (const p of points) this.lineTo(p);
    return this;
  }

  /** Şu anki imleç konumu. */
  current(): Vec {
    this.requireStart();
    return this.cursor as Vec;
  }

  close(): Path {
    this.requireStart();
    return {
      start: this.startPoint as Vec,
      segments: [...this.segs],
      closed: true,
    };
  }

  open(): Path {
    this.requireStart();
    return {
      start: this.startPoint as Vec,
      segments: [...this.segs],
      closed: false,
    };
  }

  private requireStart(): void {
    if (this.startPoint === undefined) {
      throw new Error("PathBuilder: önce moveTo çağrılmalı");
    }
  }
}

export function path(): PathBuilder {
  return new PathBuilder();
}

/** Yolun bitiş noktası (kapalıysa start). */
export function endPoint(p: Path): Vec {
  if (p.closed) return p.start;
  const last = p.segments.at(-1);
  return last === undefined ? p.start : last.to;
}

/**
 * Yolu poligona çevirir.
 *
 * Tüm boolean/offset işlemleri (Clipper2) ve dikiş dağıtımı bu çıktıyla
 * çalışır. Kapalı yollarda ilk nokta sona tekrar eklenmez.
 */
export function flattenPath(
  p: Path,
  tolerance: Mm = FLATTEN_TOLERANCE,
): Polyline {
  const out: Vec[] = [p.start];
  let cur = p.start;

  for (const seg of p.segments) {
    if (seg.kind === "line") {
      if (!vecEq(cur, seg.to)) out.push(seg.to);
    } else {
      const c: Cubic = { p0: cur, c1: seg.c1, c2: seg.c2, p1: seg.to };
      for (const pt of flattenCubic(c, tolerance)) out.push(pt);
    }
    cur = seg.to;
  }

  // Kapalı yolda kullanıcı son noktayı start'a eşit vermiş olabilir.
  if (p.closed && out.length > 1) {
    const last = out.at(-1) as Vec;
    if (vecEq(last, p.start)) out.pop();
  }

  return out;
}

/** Poligonun çevresi. Kapalıysa kapanış kenarı dahil edilir. */
export function polylineLength(poly: Polyline, closed: boolean): Mm {
  if (poly.length < 2) return 0;
  let total = 0;
  for (let i = 1; i < poly.length; i++) {
    total += distance(poly[i - 1] as Vec, poly[i] as Vec);
  }
  if (closed) {
    total += distance(poly.at(-1) as Vec, poly[0] as Vec);
  }
  return total;
}

/**
 * İşaretli alan (shoelace). İşareti dönüş yönünü verir:
 * pozitif = saat yönünün tersi (CCW).
 *
 * Clipper2'ye verilen dış hatların yönü tutarlı olmak zorunda, yoksa
 * offset içe doğru çalışır ve kalıp küçülür.
 */
export function signedArea(poly: Polyline): number {
  if (poly.length < 3) return 0;
  let sum = 0;
  for (let i = 0; i < poly.length; i++) {
    const a = poly[i] as Vec;
    const b = poly[(i + 1) % poly.length] as Vec;
    sum += cross(a, b);
  }
  return sum / 2;
}

export function isCCW(poly: Polyline): boolean {
  return signedArea(poly) > 0;
}

/** Yönü CCW'ye normalize eder. Offset işlemlerinin ön koşulu. */
export function toCCW(poly: Polyline): Polyline {
  return isCCW(poly) ? poly : [...poly].reverse();
}

export interface BBox {
  readonly min: Vec;
  readonly max: Vec;
  readonly width: Mm;
  readonly height: Mm;
}

/** Sınırlayıcı dikdörtgen. A4 sığma kontrolü ve tiling kararı için. */
export function bbox(poly: Polyline): BBox {
  if (poly.length === 0) {
    return { min: { x: 0, y: 0 }, max: { x: 0, y: 0 }, width: 0, height: 0 };
  }
  let minX = Infinity;
  let minY = Infinity;
  let maxX = -Infinity;
  let maxY = -Infinity;
  for (const p of poly) {
    if (p.x < minX) minX = p.x;
    if (p.y < minY) minY = p.y;
    if (p.x > maxX) maxX = p.x;
    if (p.y > maxY) maxY = p.y;
  }
  return {
    min: { x: minX, y: minY },
    max: { x: maxX, y: maxY },
    width: maxX - minX,
    height: maxY - minY,
  };
}

/**
 * Ardışık eşdoğrusal noktaları temizler.
 *
 * Düzleştirme sonrası binlerce nokta oluşur; PDF boyutu ve Clipper2
 * performansı için gereksiz olanları atmak gerekir. tolerance, bir
 * noktanın komşularının oluşturduğu doğrudan izinli sapmasıdır.
 */
export function simplify(poly: Polyline, tolerance: Mm = EPS): Polyline {
  if (poly.length < 3) return poly;
  const out: Vec[] = [poly[0] as Vec];
  for (let i = 1; i < poly.length - 1; i++) {
    const prev = out.at(-1) as Vec;
    const cur = poly[i] as Vec;
    const next = poly[i + 1] as Vec;
    const ab = sub(cur, prev);
    const ac = sub(next, prev);
    const lenAC = Math.hypot(ac.x, ac.y);
    if (lenAC <= EPS) continue;
    const dev = Math.abs(cross(ab, ac)) / lenAC;
    if (dev > tolerance) out.push(cur);
  }
  out.push(poly.at(-1) as Vec);
  return out;
}
