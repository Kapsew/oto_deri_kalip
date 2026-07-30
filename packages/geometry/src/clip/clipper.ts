import ClipperLib from "clipper-lib";
import type { Mm } from "../units.js";
import type { Polyline } from "../path/path.js";
import { signedArea } from "../path/path.js";
import { FLATTEN_TOLERANCE } from "../path/bezier.js";
import {
  toClipperPaths,
  fromClipperPaths,
  scaleDelta,
  CLIPPER_SCALE,
} from "./scale.js";

/**
 * Offset ve boolean işlemleri.
 *
 * NEDEN clipper-lib (Clipper 6), clipper2-js DEĞİL:
 * clipper2-js@1.2.4'ün offsetter'ı bozuk çıktı üretiyor — 100x50
 * dikdörtgeni 2mm dışa ötelediğinde sınırlar doğru (104x54) ama nokta
 * sırası karışıyor ve alan 5616 yerine 5302 çıkıyor, yani poligon kendi
 * kendini kesiyor. clipper-lib aynı testte tam 5616 veriyor.
 * clipper-lib ayrıca saf JS — WASM yükleme adımı olmadığı için tarayıcı,
 * Node ve Capacitor'da aynı çalışıyor; bu paketin saflık kuralına uyuyor.
 */

export type JoinStyle = "miter" | "round" | "square";

export interface OffsetOptions {
  /**
   * Köşe birleşim biçimi.
   * - miter: keskin köşe. Kesim hattı için doğru seçim; kalıbın köşesi
   *   fiziksel olarak keskindir.
   * - round: yuvarlatılmış. Dikiş hattı ve el rahatlığı için.
   * - square: pah kırılmış.
   */
  readonly join?: JoinStyle;
  /**
   * Miter sınırı. Çok keskin köşelerde miter uzunluğu delta'nın bu
   * katından fazla olamaz; aşarsa square'e düşer. 2 = 60 dereceye kadar
   * keskin köşeleri korur, daha keskinlerde uzayıp gitmesini engeller.
   */
  readonly miterLimit?: number;
  /**
   * Yuvarlatma yaklaşım toleransı. Varsayılan bezier düzleştirme
   * toleransıyla aynı (0.05mm) — böylece offset, eğri düzleştirmeden
   * daha kaba bir hata kaynağı olmaz.
   */
  readonly arcTolerance?: Mm;
}

function joinTypeOf(style: JoinStyle): ClipperLib.JoinType {
  switch (style) {
    case "miter":
      return ClipperLib.JoinType.jtMiter;
    case "round":
      return ClipperLib.JoinType.jtRound;
    case "square":
      return ClipperLib.JoinType.jtSquare;
  }
}

/**
 * Kapalı poligonları delta mm ötele. Pozitif = dışa, negatif = içe.
 *
 * Girdi yönü ÖNEMSİZ: clipper-lib yönü kendisi normalize eder ve çıktıyı
 * her zaman pozitif alanlı (CCW) dış kontur olarak verir. Delikler negatif
 * alanla döner.
 *
 * DİKKAT: içe öteleme parçayı yok edebilir (3mm genişliğinde bir şeridi
 * 2mm içe ötelersen hiçbir şey kalmaz). Bu durumda boş dizi döner —
 * çağıran taraf bunu kural motoru hatası olarak yüzeye çıkarmak zorunda,
 * sessizce yutmamalı.
 */
export function offsetPolygons(
  polys: readonly Polyline[],
  delta: Mm,
  options: OffsetOptions = {},
): Polyline[] {
  if (polys.length === 0) return [];

  const join = options.join ?? "miter";
  const miterLimit = options.miterLimit ?? 2;
  const arcTolerance = options.arcTolerance ?? FLATTEN_TOLERANCE;

  const co = new ClipperLib.ClipperOffset(
    miterLimit,
    arcTolerance * CLIPPER_SCALE,
  );
  co.AddPaths(
    toClipperPaths(polys),
    joinTypeOf(join),
    ClipperLib.EndType.etClosedPolygon,
  );

  const solution: ClipperLib.Paths = [];
  co.Execute(solution, scaleDelta(delta));
  return fromClipperPaths(solution);
}

/** Tek poligon için offset kısayolu. */
export function offsetPolygon(
  poly: Polyline,
  delta: Mm,
  options: OffsetOptions = {},
): Polyline[] {
  return offsetPolygons([poly], delta, options);
}

/**
 * Tek bir dış kontur bekleyen offset.
 *
 * Kalıp parçalarının çoğu tek parçalıdır; sonucun bölünmesi ya da yok
 * olması tasarım hatasının işaretidir. Bu yüzden sessizce ilk parçayı
 * almak yerine hata atar.
 */
export function offsetSingle(
  poly: Polyline,
  delta: Mm,
  options: OffsetOptions = {},
): Polyline {
  const result = offsetPolygons([poly], delta, options);
  const outers = result.filter((p) => signedArea(p) > 0);
  if (outers.length === 0) {
    throw new Error(
      `offsetSingle: ${delta}mm öteleme parçayı yok etti. ` +
        `Parça bu öteleme için çok ince.`,
    );
  }
  if (outers.length > 1) {
    throw new Error(
      `offsetSingle: ${delta}mm öteleme parçayı ${outers.length} parçaya ayırdı. ` +
        `Dar boyun ya da kendini kesen kontur olabilir.`,
    );
  }
  return outers[0] as Polyline;
}

// --- Boolean işlemleri -----------------------------------------------------

type ClipType = ClipperLib.ClipType;

function booleanOp(
  subject: readonly Polyline[],
  clip: readonly Polyline[],
  type: ClipType,
): Polyline[] {
  const c = new ClipperLib.Clipper();
  c.AddPaths(toClipperPaths(subject), ClipperLib.PolyType.ptSubject, true);
  if (clip.length > 0) {
    c.AddPaths(toClipperPaths(clip), ClipperLib.PolyType.ptClip, true);
  }
  const solution: ClipperLib.Paths = [];
  c.Execute(
    type,
    solution,
    ClipperLib.PolyFillType.pftNonZero,
    ClipperLib.PolyFillType.pftNonZero,
  );
  return fromClipperPaths(solution);
}

/** Birleşim. Katmanları tek dış hatta indirmek için. */
export function union(
  subject: readonly Polyline[],
  clip: readonly Polyline[] = [],
): Polyline[] {
  return booleanOp(subject, clip, ClipperLib.ClipType.ctUnion);
}

/** Fark. Kart penceresi, fermuar açıklığı, delik açmak için. */
export function difference(
  subject: readonly Polyline[],
  clip: readonly Polyline[],
): Polyline[] {
  return booleanOp(subject, clip, ClipperLib.ClipType.ctDifference);
}

/** Kesişim. Katman örtüşmesini (tutkal alanı) bulmak için. */
export function intersection(
  subject: readonly Polyline[],
  clip: readonly Polyline[],
): Polyline[] {
  return booleanOp(subject, clip, ClipperLib.ClipType.ctIntersection);
}

export function xor(
  subject: readonly Polyline[],
  clip: readonly Polyline[],
): Polyline[] {
  return booleanOp(subject, clip, ClipperLib.ClipType.ctXor);
}

// --- Sınıflandırma ve temizlik ---------------------------------------------

export interface ContourSet {
  /** Pozitif alanlı dış konturlar. */
  readonly outers: Polyline[];
  /** Negatif alanlı delikler. */
  readonly holes: Polyline[];
}

/**
 * Boolean/offset sonucunu dış kontur ve delik olarak ayırır.
 * PDF'te delikler ayrı çizilmek zorunda, yoksa dolgu kuralı bozulur.
 */
export function classifyContours(polys: readonly Polyline[]): ContourSet {
  const outers: Polyline[] = [];
  const holes: Polyline[] = [];
  for (const p of polys) {
    if (signedArea(p) > 0) outers.push(p);
    else holes.push(p);
  }
  return { outers, holes };
}

/** Toplam net alan (delikler düşülmüş). Malzeme hesabı için. */
export function netArea(polys: readonly Polyline[]): number {
  return polys.reduce((acc, p) => acc + signedArea(p), 0);
}

/**
 * Kendini kesen konturları düzeltir.
 *
 * Kullanıcı kalıbı ya da içeri aktarılmış çizim bozuk olabilir; offset'e
 * bozuk kontur vermek sessizce yanlış sonuç üretir.
 */
export function simplifyPolygons(polys: readonly Polyline[]): Polyline[] {
  const result = ClipperLib.Clipper.SimplifyPolygons(
    toClipperPaths(polys),
    ClipperLib.PolyFillType.pftNonZero,
  );
  return fromClipperPaths(result);
}

/**
 * Çok yakın ardışık noktaları ve neredeyse eşdoğrusal köşeleri temizler.
 * Bezier düzleştirmesi sonrası nokta sayısını düşürmek için.
 */
export function cleanPolygons(
  polys: readonly Polyline[],
  tolerance: Mm = FLATTEN_TOLERANCE / 2,
): Polyline[] {
  const result = ClipperLib.Clipper.CleanPolygons(
    toClipperPaths(polys),
    tolerance * CLIPPER_SCALE,
  );
  return fromClipperPaths(result).filter((p) => p.length >= 3);
}
