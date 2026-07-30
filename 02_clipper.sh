#!/usr/bin/env bash
#
# Faz 1 / Adim 5 — Clipper entegrasyonu (offset + boolean + pay hesaplari)
#
# Kullanim:
#   chmod +x 02_clipper.sh
#   ./02_clipper.sh
#
# Repo kokunde calistirilmalidir (package.json'in oldugu dizin).
# Idempotent: tekrar calistirmak sorun cikarmaz, dosyalari uzerine yazar.

set -euo pipefail

# --- Ortam kontrolu --------------------------------------------------------
if [ ! -f "pnpm-workspace.yaml" ] || [ ! -d "packages/geometry" ]; then
  echo "HATA: Bu script repo kokunde calistirilmali." >&2
  echo "       Beklenen: ./pnpm-workspace.yaml ve ./packages/geometry" >&2
  exit 1
fi

if ! command -v pnpm > /dev/null 2>&1; then
  echo "HATA: pnpm bulunamadi. Kurulum: npm i -g pnpm@9" >&2
  exit 1
fi

echo "==> Bagimliliklar ekleniyor (clipper-lib)"
cd packages/geometry
pnpm add clipper-lib@6.4.2
pnpm add -D @types/clipper-lib@6.4.0
cd ../..

echo "==> Dizin olusturuluyor"
mkdir -p packages/geometry/src/clip

echo "==> packages/geometry/src/clip/scale.ts"
cat > packages/geometry/src/clip/scale.ts << 'ODK_EOF_0'
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
ODK_EOF_0

echo "==> packages/geometry/src/clip/clipper.ts"
cat > packages/geometry/src/clip/clipper.ts << 'ODK_EOF_1'
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
ODK_EOF_1

echo "==> packages/geometry/src/clip/allowance.ts"
cat > packages/geometry/src/clip/allowance.ts << 'ODK_EOF_2'
import type { Mm } from "../units.js";
import { EPS, IRON_PITCHES } from "../units.js";
import type { Polyline } from "../path/path.js";
import { bbox, signedArea } from "../path/path.js";
import {
  offsetPolygons,
  offsetSingle,
  intersection,
  difference,
} from "./clipper.js";

/**
 * Kesim ve dikiş paylarının uygulanması.
 *
 * Bu dosya, saf geometriyi hedef kitlemizin fiziksel gerçekliğine bağlar:
 * A4'e basıp ELLE kesen kullanıcı. Öteleme değerleri estetik tercih değil,
 * ölçülmüş hata kaynaklarının telafisi.
 */

/**
 * Kalem payı seçenekleri.
 *
 * Kullanıcı şablonu kartona yapıştırıp deriye çiziyor. Kalem/bıçak ucu
 * şablon kenarından dışa kaçar: kurşun kalem ~0.3mm, keçeli ~0.5mm.
 * Telafi edilmezse parça her kenardan o kadar büyük çıkar ve katmanlar
 * birbirine oturmaz.
 */
export const PEN_ALLOWANCES: readonly Mm[] = [0, 0.3, 0.5];

/**
 * Varsayılan dikiş payı: kesim kenarından 3.5mm içeride.
 *
 * 3mm altı deri yırtılma riski taşır (özellikle 1.0-1.2mm dana derisinde),
 * 4.5mm üstü gereksiz malzeme kaybı ve şişkin kenar demek. 3.5mm hobi
 * kalıplarında yaygın değer.
 */
export const DEFAULT_STITCH_MARGIN: Mm = 3.5;

export interface CutLineOptions {
  /**
   * Kalem payı (mm). Şablonun dış hattı bu kadar İÇE alınır, böylece
   * kullanıcı dışından çizdiğinde nominal ölçüye ulaşır.
   */
  readonly penAllowance?: Mm;
  /** Lazer kerf (mm). Hobici için 0; lazer kullananda kerf/2 içe alınır. */
  readonly kerf?: Mm;
}

/**
 * Nominal parça hattından basılacak kesim hattını üretir.
 *
 * Kalem payı İÇE uygulanır — sezgiye ters gelebilir. Mantık: kullanıcı
 * çizgi izinin DIŞINDAN keser, kalem ucu da dışa kaçar; ikisi birlikte
 * parçayı büyütür. Şablonu o kadar küçük basarak nominal ölçüde
 * buluşuruz.
 */
export function cutLine(
  nominal: Polyline,
  options: CutLineOptions = {},
): Polyline {
  const pen = options.penAllowance ?? 0;
  const kerf = options.kerf ?? 0;
  const inset = pen + kerf / 2;
  if (inset <= EPS) return nominal;
  return offsetSingle(nominal, -inset, { join: "miter" });
}

/**
 * Kesim hattından dikiş hattını üretir.
 *
 * Yuvarlak birleşim kullanılır: dikiş hattı köşelerde keskin dönmez,
 * çünkü iplik köşeyi yay çizerek döner. Keskin miter köşe, delik
 * dağıtıcısına gerçekte olmayan bir kırılma bildirir.
 */
export function stitchLine(
  cut: Polyline,
  margin: Mm = DEFAULT_STITCH_MARGIN,
): Polyline {
  return offsetSingle(cut, -margin, { join: "round" });
}

/**
 * İki katmanın örtüşen alanı, dikiş hattının içinde kalan kısım hariç.
 *
 * Tutkal sadece dikiş hattının DIŞINDA kalan bant üzerine sürülür;
 * içeriye taşırsa kart yuvası yapışır ve ürün çöp olur. Bu fonksiyon
 * PDF'te taranacak tutkal bandını verir.
 */
export function glueBand(
  layerA: Polyline,
  layerB: Polyline,
  stitchMargin: Mm = DEFAULT_STITCH_MARGIN,
): Polyline[] {
  const overlap = intersection([layerA], [layerB]);
  if (overlap.length === 0) return [];

  const inner = offsetPolygons(overlap, -stitchMargin, { join: "round" });
  // Örtüşme dikiş payından daha ince: tamamı tutkal bandı olur.
  if (inner.length === 0) return overlap;

  return difference(overlap, inner);
}

/**
 * Parçanın en dar yerinin genişliği.
 *
 * NASIL: parçayı adım adım içe öteler ve hangi ötelemede yok olduğunu
 * ikili aramayla bulur. Yok olma eşiği d ise en dar boyun 2d'dir
 * (öteleme her iki kenardan aynı anda gelir).
 *
 * NİYE: kural motorunun "bu parça çok ince, dikiş payı sığmaz" kontrolü
 * için. Kart yuvası ağzı ile kesim kenarı arasında 8mm bırakmayı şart
 * koştuk; bu fonksiyon o kuralı geometriden bağımsız doğrular.
 *
 * Doğruluk `tolerance` kadardır; varsayılan 0.05mm baskı hassasiyetimizle
 * aynı mertebede.
 */
export function narrowestWidth(poly: Polyline, tolerance: Mm = 0.05): Mm {
  const b = bbox(poly);
  const hiBound = Math.min(b.width, b.height) / 2 + tolerance;
  let hi = hiBound;
  let lo = 0;

  // Üst sınırda hâlâ sağlamsa (olmaması gerekir; bbox yarısı her şeyi
  // yok eder) bbox kısa kenarını döndür.
  if (isIntact(poly, hi)) return Math.min(b.width, b.height);

  // Sonuç 2*lo olduğu için, istenen doğruluğa ulaşmak adına döngü
  // tolerance/2'de durur.
  while (hi - lo > tolerance / 2) {
    const mid = (lo + hi) / 2;
    if (isIntact(poly, mid)) lo = mid;
    else hi = mid;
  }
  return lo * 2;
}

/**
 * Parça bu ötelemede TEK parça olarak sağlam mı?
 *
 * DİKKAT: sadece "alan kaldı mı" diye bakmak yetmez. Kum saati şeklinde
 * bir parça boynundan koptuğunda iki ayrı parçaya döner ve toplam alan
 * hâlâ pozitiftir. O yüzden ölçüt "tam olarak bir dış kontur" olmalı;
 * aksi halde en dar boyun yerine tamamen yok olma eşiği ölçülür.
 */
function isIntact(poly: Polyline, inset: Mm): boolean {
  if (inset <= EPS) return true;
  const r = offsetPolygons([poly], -inset, { join: "miter" });
  const outers = r.filter((p) => signedArea(p) > EPS);
  return outers.length === 1;
}

/**
 * Verilen kenar uzunluğu için kullanılabilir iron adımı ve delik sayısı.
 *
 * Fiziksel takım sabit adımlıdır; adımı serbest seçemeyiz. Bu yüzden
 * kenarı tam bölmeye en yakın adımı seçip sapmayı raporluyoruz.
 * Sapma, delik başına düşen hatadır — 0.15mm üstü gözle görülür.
 */
export interface PitchFit {
  readonly pitch: Mm;
  readonly holes: number;
  readonly actualPitch: Mm;
  readonly deviationPerHole: Mm;
}

export function bestPitchFit(
  edgeLength: Mm,
  pitches: readonly Mm[] = IRON_PITCHES,
): PitchFit | undefined {
  let best: PitchFit | undefined;
  for (const pitch of pitches) {
    const n = Math.round(edgeLength / pitch);
    if (n < 1) continue;
    const actual = edgeLength / n;
    const dev = Math.abs(actual - pitch);
    if (best === undefined || dev < best.deviationPerHole) {
      best = {
        pitch,
        holes: n,
        actualPitch: actual,
        deviationPerHole: dev,
      };
    }
  }
  return best;
}
ODK_EOF_2

echo "==> packages/geometry/src/clip/clipper.test.ts"
cat > packages/geometry/src/clip/clipper.test.ts << 'ODK_EOF_3'
import { describe, it, expect } from "vitest";
import { vec } from "../vec.js";
import { path, flattenPath, signedArea, bbox } from "../path/path.js";
import { CLIPPER_SCALE, SCALE_MATCHES_EPS } from "./scale.js";
import {
  offsetPolygon,
  offsetPolygons,
  offsetSingle,
  union,
  difference,
  intersection,
  xor,
  classifyContours,
  netArea,
  simplifyPolygons,
  cleanPolygons,
} from "./clipper.js";

/** dikdörtgen üretici, CCW, sol alt köşe (x0,y0). */
function rect(x0: number, y0: number, w: number, h: number) {
  return flattenPath(
    path()
      .moveTo(vec(x0, y0))
      .lineTo(vec(x0 + w, y0))
      .lineTo(vec(x0 + w, y0 + h))
      .lineTo(vec(x0, y0 + h))
      .close(),
  );
}

const R100x50 = rect(0, 0, 100, 50);

describe("ölçek köprüsü", () => {
  it("ölçek EPS ile tutarlı: 1 birim = 1 mikron", () => {
    expect(CLIPPER_SCALE).toBe(1000);
    expect(SCALE_MATCHES_EPS).toBe(true);
  });
});

describe("offset — kesin alan doğrulaması", () => {
  it("dışa 2mm: 100x50 -> 104x54, alan tam 5616", () => {
    const r = offsetPolygon(R100x50, 2, { join: "miter" });
    expect(r).toHaveLength(1);
    expect(signedArea(r[0] as ReturnType<typeof rect>)).toBeCloseTo(5616, 6);
    const b = bbox(r[0] as ReturnType<typeof rect>);
    expect(b.width).toBeCloseTo(104, 6);
    expect(b.height).toBeCloseTo(54, 6);
  });

  it("içe 2mm: 96x46, alan tam 4416", () => {
    const r = offsetPolygon(R100x50, -2, { join: "miter" });
    expect(signedArea(r[0] as ReturnType<typeof rect>)).toBeCloseTo(4416, 6);
  });

  it("sıfır öteleme şekli korur", () => {
    const r = offsetPolygon(R100x50, 0, { join: "miter" });
    expect(signedArea(r[0] as ReturnType<typeof rect>)).toBeCloseTo(5000, 3);
  });

  it("girdi yönü sonucu etkilemez", () => {
    // clipper-lib yönü kendisi normalize eder; CW girdide de dışa öteler.
    const cw = [...R100x50].reverse();
    const a = offsetPolygon(R100x50, 2, { join: "miter" });
    const b = offsetPolygon(cw, 2, { join: "miter" });
    expect(signedArea(b[0] as ReturnType<typeof rect>)).toBeCloseTo(
      signedArea(a[0] as ReturnType<typeof rect>),
      6,
    );
  });

  it("çıktı her zaman pozitif alanlı (CCW)", () => {
    const cw = [...R100x50].reverse();
    for (const input of [R100x50, cw]) {
      const r = offsetPolygon(input, 1.5);
      expect(signedArea(r[0] as ReturnType<typeof rect>)).toBeGreaterThan(0);
    }
  });

  it("round birleşim köşeleri yuvarlar: alan miter'dan küçük", () => {
    const m = offsetPolygon(R100x50, 2, { join: "miter" });
    const rd = offsetPolygon(R100x50, 2, { join: "round" });
    const am = signedArea(m[0] as ReturnType<typeof rect>);
    const ar = signedArea(rd[0] as ReturnType<typeof rect>);
    expect(ar).toBeLessThan(am);
    // Kayıp = 4 köşede (4 - pi) * r^2 = 0.8584 * 4 = 3.43mm²
    expect(am - ar).toBeCloseTo(3.43, 0);
    expect((rd[0] as ReturnType<typeof rect>).length).toBeGreaterThan(4);
  });

  it("arcTolerance küçüldükçe yuvarlatma nokta sayısı artar", () => {
    const coarse = offsetPolygon(R100x50, 5, { join: "round", arcTolerance: 0.5 });
    const fine = offsetPolygon(R100x50, 5, { join: "round", arcTolerance: 0.01 });
    expect((fine[0] as ReturnType<typeof rect>).length).toBeGreaterThan(
      (coarse[0] as ReturnType<typeof rect>).length,
    );
  });
});

describe("offset — dejenere durumlar", () => {
  it("ince şeridi içe öteleme yok eder, boş dizi döner", () => {
    const thin = rect(0, 0, 100, 3);
    expect(offsetPolygon(thin, -2)).toHaveLength(0);
  });

  it("offsetSingle yok olmayı sessizce yutmaz, hata atar", () => {
    // Bu davranış kritik: sessiz boş sonuç, kullanıcıya eksik kalıp
    // basılması demek olurdu.
    const thin = rect(0, 0, 100, 3);
    expect(() => offsetSingle(thin, -2)).toThrow(/yok etti/);
  });

  it("offsetSingle parçalanmayı da yakalar", () => {
    // Kum saati: dar boyun içe ötelemede kopar.
    const hourglass = flattenPath(
      path()
        .moveTo(vec(0, 0))
        .lineTo(vec(40, 0))
        .lineTo(vec(21, 20))
        .lineTo(vec(40, 40))
        .lineTo(vec(0, 40))
        .lineTo(vec(19, 20))
        .close(),
    );
    expect(() => offsetSingle(hourglass, -3)).toThrow(/parçaya ayırdı/);
  });

  it("boş girdi boş çıktı", () => {
    expect(offsetPolygons([], 2)).toHaveLength(0);
  });
});

describe("offset — delikli şekil", () => {
  const outer = rect(0, 0, 100, 50);
  const hole = [...rect(40, 20, 20, 10)].reverse(); // delik CW

  it("dışa öteleme dış konturu büyütür, deliği küçültür", () => {
    const r = offsetPolygons([outer, hole], 1, { join: "miter" });
    const { outers, holes } = classifyContours(r);
    expect(outers).toHaveLength(1);
    expect(holes).toHaveLength(1);
    // dış: 102x52 = 5304, delik: 18x8 = 144
    expect(signedArea(outers[0] as ReturnType<typeof rect>)).toBeCloseTo(5304, 6);
    expect(Math.abs(signedArea(holes[0] as ReturnType<typeof rect>))).toBeCloseTo(144, 6);
  });

  it("netArea delikleri düşer", () => {
    const r = offsetPolygons([outer, hole], 1, { join: "miter" });
    expect(netArea(r)).toBeCloseTo(5304 - 144, 6);
  });
});

describe("boolean işlemleri", () => {
  const a = rect(0, 0, 100, 50); // 5000
  const b = rect(50, 20, 100, 10); // x 50..150, y 20..30

  it("kesişim 50x10 = 500", () => {
    expect(netArea(intersection([a], [b]))).toBeCloseTo(500, 6);
  });

  it("fark 5000 - 500 = 4500", () => {
    expect(netArea(difference([a], [b]))).toBeCloseTo(4500, 6);
  });

  it("birleşim 5000 + 500 = 5500", () => {
    expect(netArea(union([a], [b]))).toBeCloseTo(5500, 6);
  });

  it("xor = birleşim - kesişim = 5000", () => {
    expect(netArea(xor([a], [b]))).toBeCloseTo(5000, 6);
  });

  it("fark delik üretir (kart penceresi senaryosu)", () => {
    const window = rect(20, 15, 40, 20); // tamamen içeride
    const r = difference([a], [window]);
    const { outers, holes } = classifyContours(r);
    expect(outers).toHaveLength(1);
    expect(holes).toHaveLength(1);
    expect(netArea(r)).toBeCloseTo(5000 - 800, 6);
  });

  it("clip verilmezse union kendi içinde birleştirir", () => {
    const c = rect(90, 0, 20, 50);
    expect(netArea(union([a, c]))).toBeCloseTo(5000 + 20 * 50 - 10 * 50, 6);
  });
});

describe("temizlik", () => {
  it("simplifyPolygons kendini kesen konturu düzeltir", () => {
    // Papyon: kendini ortada kesiyor.
    const bowtie = [vec(0, 0), vec(10, 10), vec(0, 10), vec(10, 0)];
    const r = simplifyPolygons([bowtie]);
    expect(r.length).toBeGreaterThanOrEqual(1);
    // İki üçgen, her biri 25; net alan sıfır olmamalı.
    expect(Math.abs(netArea(r))).toBeGreaterThan(0);
  });

  it("cleanPolygons çok yakın noktaları atar", () => {
    const noisy = [
      vec(0, 0),
      vec(0.001, 0),
      vec(100, 0),
      vec(100, 50),
      vec(0, 50),
    ];
    const r = cleanPolygons([noisy]);
    expect((r[0] as ReturnType<typeof rect>).length).toBeLessThan(noisy.length);
  });

  it("cleanPolygons 3 noktadan az kalan konturu atar", () => {
    expect(cleanPolygons([[vec(0, 0), vec(0.0005, 0)]])).toHaveLength(0);
  });
});
ODK_EOF_3

echo "==> packages/geometry/src/clip/allowance.test.ts"
cat > packages/geometry/src/clip/allowance.test.ts << 'ODK_EOF_4'
import { describe, it, expect } from "vitest";
import { vec } from "../vec.js";
import { path, flattenPath, signedArea, bbox } from "../path/path.js";
import { netArea } from "./clipper.js";
import {
  PEN_ALLOWANCES,
  DEFAULT_STITCH_MARGIN,
  cutLine,
  stitchLine,
  glueBand,
  narrowestWidth,
  bestPitchFit,
} from "./allowance.js";

function rect(x0: number, y0: number, w: number, h: number) {
  return flattenPath(
    path()
      .moveTo(vec(x0, y0))
      .lineTo(vec(x0 + w, y0))
      .lineTo(vec(x0 + w, y0 + h))
      .lineTo(vec(x0, y0 + h))
      .close(),
  );
}

describe("kalem payı", () => {
  it("seçenekler 0 / 0.3 / 0.5", () => {
    expect(PEN_ALLOWANCES).toEqual([0, 0.3, 0.5]);
  });

  it("pay 0 iken hat değişmez", () => {
    const nominal = rect(0, 0, 100, 50);
    expect(signedArea(cutLine(nominal, { penAllowance: 0 }))).toBeCloseTo(5000, 6);
  });

  it("0.3mm pay her kenardan içe alır: 99.4 x 49.4", () => {
    // Kalem ucu dışa kaçtığı için şablon KÜÇÜK basılır.
    const r = cutLine(rect(0, 0, 100, 50), { penAllowance: 0.3 });
    const b = bbox(r);
    expect(b.width).toBeCloseTo(99.4, 6);
    expect(b.height).toBeCloseTo(49.4, 6);
  });

  it("kerf yarısı kadar içe alır", () => {
    const r = cutLine(rect(0, 0, 100, 50), { kerf: 0.2 });
    expect(bbox(r).width).toBeCloseTo(99.8, 6);
  });

  it("kalem payı ve kerf toplanır", () => {
    const r = cutLine(rect(0, 0, 100, 50), { penAllowance: 0.3, kerf: 0.2 });
    expect(bbox(r).width).toBeCloseTo(99.2, 6);
  });
});

describe("dikiş hattı", () => {
  it("varsayılan pay 3.5mm", () => {
    expect(DEFAULT_STITCH_MARGIN).toBe(3.5);
  });

  it("kesim hattından 3.5mm içeride", () => {
    const s = stitchLine(rect(0, 0, 100, 50));
    const b = bbox(s);
    expect(b.width).toBeCloseTo(93, 1);
    expect(b.height).toBeCloseTo(43, 1);
  });

  it("dışbükey köşeler İÇE ötelemede keskin kalır", () => {
    // Beklenti düzeltildi. Yuvarlatma yalnızca DIŞA ötelemede dışbükey
    // köşelere uygulanır; içe ötelemede köşe doğal olarak keskin kalır ve
    // bu geometrik olarak doğrudur.
    //
    // SONUÇ: dikiş hattının köşesini yuvarlamak offset'in yan ürünü
    // olarak elde edilemez — ayrı ve bilinçli bir adım olmak zorunda
    // (Adım 7'de dikiş dağıtıcısıyla birlikte ele alınacak).
    const s = stitchLine(rect(0, 0, 100, 50));
    expect(s).toHaveLength(4);
  });

  it("pay parçadan büyükse hata atar", () => {
    expect(() => stitchLine(rect(0, 0, 100, 5), 3.5)).toThrow();
  });
});

describe("tutkal bandı", () => {
  it("örtüşmenin dış bandını verir, iç bölgeyi bırakır", () => {
    const a = rect(0, 0, 100, 50);
    const b = rect(0, 0, 100, 50);
    const band = glueBand(a, b, 3.5);
    // 5000 - (93 x 43 ≈ 3999) ≈ 1001, yuvarlatma nedeniyle biraz fazla
    expect(netArea(band)).toBeGreaterThan(950);
    expect(netArea(band)).toBeLessThan(1050);
  });

  it("örtüşme yoksa boş", () => {
    expect(glueBand(rect(0, 0, 10, 10), rect(50, 50, 10, 10))).toHaveLength(0);
  });

  it("örtüşme dikiş payından inceyse tamamı tutkal", () => {
    const a = rect(0, 0, 100, 50);
    const b = rect(0, 0, 100, 4); // 4mm şerit, 3.5mm pay sığmaz
    const band = glueBand(a, b, 3.5);
    expect(netArea(band)).toBeCloseTo(400, 0);
  });
});

describe("narrowestWidth", () => {
  it("dikdörtgende kısa kenarı bulur", () => {
    expect(narrowestWidth(rect(0, 0, 100, 20))).toBeCloseTo(20, 1);
    expect(narrowestWidth(rect(0, 0, 50, 12))).toBeCloseTo(12, 1);
  });

  it("kum saatinde dar boynu bulur (yok olma eşiğini değil)", () => {
    // Boyun genişliği 2mm (x=19..21). Parça boynundan koptuğunda iki
    // parçaya ayrılır ama toplam alan pozitif kalır; ölçüt bunu yakalamalı.
    const hourglass = flattenPath(
      path()
        .moveTo(vec(0, 0))
        .lineTo(vec(40, 0))
        .lineTo(vec(21, 20))
        .lineTo(vec(40, 40))
        .lineTo(vec(0, 40))
        .lineTo(vec(19, 20))
        .close(),
    );
    const w = narrowestWidth(hourglass);
    expect(w).toBeGreaterThan(1);
    expect(w).toBeLessThan(4);
  });

  it("kural kontrolü: 8mm kenar payı kuralı geometriden doğrulanabilir", () => {
    // Kart yuvası ağzı ile kesim kenarı arasında en az 8mm olmalı.
    const okPart = rect(0, 0, 100, 30);
    const tooThin = rect(0, 0, 100, 6);
    expect(narrowestWidth(okPart)).toBeGreaterThan(8);
    expect(narrowestWidth(tooThin)).toBeLessThan(8);
  });
});

describe("bestPitchFit", () => {
  it("100mm kenarda 4.0mm adım tam oturur: 25 delik, sapma 0", () => {
    const fit = bestPitchFit(100);
    expect(fit).toBeDefined();
    expect(fit?.deviationPerHole).toBeCloseTo(0, 6);
    expect((fit?.pitch as number) * (fit?.holes as number)).toBeCloseTo(100, 6);
  });

  it("gerçek adım kenarı tam böler", () => {
    for (const len of [43, 67.5, 93, 110.4]) {
      const fit = bestPitchFit(len);
      expect(fit).toBeDefined();
      expect((fit?.actualPitch as number) * (fit?.holes as number)).toBeCloseTo(len, 6);
    }
  });

  it("sapma her zaman kabul edilebilir bandda (< 0.15mm)", () => {
    // Adım kümesi yeterince yoğun olduğu için her uzunlukta iyi bir
    // eşleşme bulunmalı. Bulunamazsa adım listesi yetersiz demektir.
    for (let len = 20; len <= 200; len += 0.5) {
      const fit = bestPitchFit(len);
      expect(fit?.deviationPerHole).toBeLessThan(0.15);
    }
  });

  it("adımdan kısa kenarda tanımsız döner", () => {
    expect(bestPitchFit(1, [3.85])).toBeUndefined();
  });
});
ODK_EOF_4

echo "==> src/index.ts guncelleniyor"
cat > packages/geometry/src/index.ts << 'ODK_EOF_INDEX'
/**
 * @odk/geometry — saf geometri cekirdegi.
 *
 * KURAL: Bu paket React, DOM, Node fs veya herhangi bir platform API'si
 * import ETMEZ. Tarayicida, Node'da ve Capacitor icinde ayni sekilde
 * calismasi mobil paketlemenin on kosulu.
 */

export * from "./units.js";
export * from "./vec.js";
export * from "./path/bezier.js";
export * from "./path/path.js";
export * from "./path/arclength.js";
export * from "./clip/scale.js";
export * from "./clip/clipper.js";
export * from "./clip/allowance.js";
ODK_EOF_INDEX

echo "==> Testler"
pnpm --filter @odk/geometry test

echo "==> Typecheck"
pnpm typecheck

cat << 'ODK_DONE'

============================================================
ADIM 5 TAMAM
============================================================

Eklenen dosyalar:
  packages/geometry/src/clip/scale.ts            Mm <-> tamsayi kopru
  packages/geometry/src/clip/clipper.ts          offset + boolean
  packages/geometry/src/clip/allowance.ts        kalem payi, dikis hatti,
                                                 tutkal bandi, en dar boyun
  packages/geometry/src/clip/clipper.test.ts     23 test
  packages/geometry/src/clip/allowance.test.ts   19 test

Simdi git komutlari:

  git add -A
  git commit -m "Faz 1 Adim 5: Clipper entegrasyonu (offset, boolean, pay hesaplari)

- clipper-lib@6.4.2 secildi; clipper2-js@1.2.4'un offsetter'i bozuk
  cikti veriyor (100x50 +2mm -> alan 5616 yerine 5302, kendini kesen kontur)
- CLIPPER_SCALE=1000: bir tamsayi birimi tam olarak EPS (1 mikron)
- offsetSingle yok olma ve parcalanmayi sessizce yutmaz, hata atar
- narrowestWidth: kopmayi da tespit eder, sadece yok olmayi degil
- kalem payi ICE uygulanir (kalem ucu disa kacar)
- 114 test geciyor, typecheck temiz"

  git push

Sonraki adim: Adim 6 — kesit cozucu (nortr eksen boyunca kivrim payi).
Bunun icin olculmus gercek bir kartlik verisi gerekiyor.

ODK_DONE
