import type { IntPoint, Path as ClipPath, Paths as ClipPaths } from "clipper-lib";
import type { Mm } from "../units.js";
import { EPS } from "../units.js";
import type { Vec } from "../vec.js";
import type { Polyline } from "../path/path.js";

/**
 * Clipper tamsayı koordinatlarla çalışır. Ölçek faktörü keyfi değil:
 * 1000 seçildi çünkü EPS = 0.001mm, yani bir tamsayı birimi tam olarak
 * bir mikrona karşılık gelir. Motorun tolerans tanımıyla kesim
 * kütüphanesinin çözünürlüğü aynı olur; ikisi arasında "kayıp hassasiyet"
 * bandı kalmaz.
 *
 * Daha büyük ölçek (1e6) taşma riski getirir, daha küçük (100) EPS'in
 * altına iner ve yuvarlama artığı üretir.
 */
export const CLIPPER_SCALE = 1000;

/** EPS ile tutarlılık kontrolü — biri değişirse diğeri de değişmeli. */
export const SCALE_MATCHES_EPS = Math.abs(1 / CLIPPER_SCALE - EPS) < 1e-12;

export function toClipperPoint(p: Vec): IntPoint {
  return {
    X: Math.round(p.x * CLIPPER_SCALE),
    Y: Math.round(p.y * CLIPPER_SCALE),
  };
}

export function fromClipperPoint(p: IntPoint): Vec {
  return { x: p.X / CLIPPER_SCALE, y: p.Y / CLIPPER_SCALE };
}

export function toClipperPath(poly: Polyline): ClipPath {
  return poly.map(toClipperPoint);
}

export function fromClipperPath(path: ClipPath): Polyline {
  return path.map(fromClipperPoint);
}

export function toClipperPaths(polys: readonly Polyline[]): ClipPaths {
  return polys.map(toClipperPath);
}

export function fromClipperPaths(paths: ClipPaths): Polyline[] {
  return paths.map(fromClipperPath);
}

/** mm cinsinden bir mesafeyi Clipper birimine çevirir. */
export function scaleDelta(mm: Mm): number {
  return mm * CLIPPER_SCALE;
}
