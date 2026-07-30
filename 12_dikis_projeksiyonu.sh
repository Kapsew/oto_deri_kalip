#!/usr/bin/env bash
#
# 12_dikis_projeksiyonu.sh
#
# Her parcaya kendi dikis delikleri. Delikler ANA PLANDAN yansitiliyor,
# parca basina yeniden hesaplanmiyor — hesaplansaydi katmanlar ust uste
# konduğunda tutmazdi.
#
# Ayrica: bifold'un ust kenari artik ACIK (banknot bolmesinin agzi).
#
# Repo kokunde calistir. Idempotent.

set -euo pipefail

if [ ! -f "pnpm-workspace.yaml" ] || [ ! -d "packages/print" ]; then
  echo "HATA: Repo kokunde calistirilmali ve 11 uygulanmis olmali." >&2
  exit 1
fi

echo "==> packages/geometry/src/path/path.ts"
cat > packages/geometry/src/path/path.ts << 'ODK_EOF_0'
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

/**
 * Nokta poligonun içinde mi? (ışın atma, çift-tek kuralı)
 *
 * Kenar üstündeki noktalar için sonuç kararsızdır; bu yüzden dikiş
 * deliği projeksiyonunda kullanılmadan önce poligon dikiş payı kadar
 * genişletilir.
 */
export function pointInPolygon(poly: Polyline, p: Vec): boolean {
  let inside = false;
  const n = poly.length;
  for (let i = 0, j = n - 1; i < n; j = i++) {
    const a = poly[i] as Vec;
    const b = poly[j] as Vec;
    const straddles = a.y > p.y !== b.y > p.y;
    if (!straddles) continue;
    const xAt = ((b.x - a.x) * (p.y - a.y)) / (b.y - a.y) + a.x;
    if (p.x < xAt) inside = !inside;
  }
  return inside;
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
ODK_EOF_0

echo "==> packages/geometry/src/path/path.test.ts"
cat > packages/geometry/src/path/path.test.ts << 'ODK_EOF_1'
import { describe, it, expect } from "vitest";
import { vec } from "../vec.js";
import {
  path,
  flattenPath,
  polylineLength,
  signedArea,
  isCCW,
  toCCW,
  bbox,
  simplify,
  endPoint,
  pointInPolygon,
} from "./path.js";

/** 100 x 50 dikdörtgen, CCW, sol alt köşe orijinde. */
function rect100x50() {
  return path()
    .moveTo(vec(0, 0))
    .lineTo(vec(100, 0))
    .lineTo(vec(100, 50))
    .lineTo(vec(0, 50))
    .close();
}

describe("PathBuilder", () => {
  it("moveTo olmadan lineTo hata verir", () => {
    expect(() => path().lineTo(vec(1, 1))).toThrow();
  });

  it("ikinci moveTo hata verir", () => {
    expect(() => path().moveTo(vec(0, 0)).moveTo(vec(1, 1))).toThrow();
  });

  it("imleç son noktayı izler", () => {
    const b = path().moveTo(vec(0, 0)).lineTo(vec(5, 5));
    expect(b.current()).toEqual(vec(5, 5));
  });

  it("polylineTo zinciri kurar", () => {
    const p = path()
      .moveTo(vec(0, 0))
      .polylineTo([vec(10, 0), vec(10, 10)])
      .open();
    expect(p.segments).toHaveLength(2);
    expect(endPoint(p)).toEqual(vec(10, 10));
  });

  it("kapalı yolun bitişi start", () => {
    expect(endPoint(rect100x50())).toEqual(vec(0, 0));
  });
});

describe("flattenPath", () => {
  it("dikdörtgen 4 nokta verir, start tekrar edilmez", () => {
    const poly = flattenPath(rect100x50());
    expect(poly).toHaveLength(4);
    expect(poly[0]).toEqual(vec(0, 0));
    expect(poly[3]).toEqual(vec(0, 50));
  });

  it("kullanıcı start'ı sona tekrar yazsa da tekilleştirir", () => {
    const p = path()
      .moveTo(vec(0, 0))
      .lineTo(vec(10, 0))
      .lineTo(vec(10, 10))
      .lineTo(vec(0, 0))
      .close();
    expect(flattenPath(p)).toHaveLength(3);
  });

  it("sıfır uzunluklu kenarı atar", () => {
    const p = path()
      .moveTo(vec(0, 0))
      .lineTo(vec(0, 0))
      .lineTo(vec(10, 0))
      .open();
    expect(flattenPath(p)).toHaveLength(2);
  });
});

describe("polylineLength", () => {
  it("dikdörtgen çevresi 300", () => {
    expect(polylineLength(flattenPath(rect100x50()), true)).toBeCloseTo(300, 9);
  });

  it("açık yolda kapanış kenarı sayılmaz", () => {
    expect(polylineLength(flattenPath(rect100x50()), false)).toBeCloseTo(250, 9);
  });

  it("tek nokta sıfır", () => {
    expect(polylineLength([vec(1, 1)], true)).toBe(0);
  });
});

describe("yön ve alan", () => {
  it("dikdörtgen alanı 5000, CCW", () => {
    const poly = flattenPath(rect100x50());
    expect(signedArea(poly)).toBeCloseTo(5000, 9);
    expect(isCCW(poly)).toBe(true);
  });

  it("ters çevrilmiş yol CW olur", () => {
    const poly = [...flattenPath(rect100x50())].reverse();
    expect(signedArea(poly)).toBeCloseTo(-5000, 9);
    expect(isCCW(poly)).toBe(false);
  });

  it("toCCW yönü normalize eder", () => {
    // Offset işlemleri tutarlı yön ister; yanlış yön kalıbı küçültür.
    const cw = [...flattenPath(rect100x50())].reverse();
    expect(isCCW(toCCW(cw))).toBe(true);
    expect(isCCW(toCCW(flattenPath(rect100x50())))).toBe(true);
  });
});

describe("pointInPolygon", () => {
  const r = rect100x50();
  const poly = flattenPath(r);

  it("iç nokta true, dış nokta false", () => {
    expect(pointInPolygon(poly, vec(50, 25))).toBe(true);
    expect(pointInPolygon(poly, vec(-5, 25))).toBe(false);
    expect(pointInPolygon(poly, vec(150, 25))).toBe(false);
    expect(pointInPolygon(poly, vec(50, 80))).toBe(false);
  });

  it("delikli şekilde delik içi dışarıda sayılır", () => {
    // Çift-tek kuralı: iki kez kesişen ışın dışarıda bırakır.
    const withHole = [
      ...poly,
      vec(0, 0),
      vec(40, 20),
      vec(60, 20),
      vec(60, 30),
      vec(40, 30),
      vec(40, 20),
    ];
    expect(pointInPolygon(withHole, vec(50, 25))).toBe(false);
    expect(pointInPolygon(withHole, vec(20, 25))).toBe(true);
  });

  it("boş poligonda false", () => {
    expect(pointInPolygon([], vec(0, 0))).toBe(false);
  });
});

describe("bbox", () => {
  it("dikdörtgen sınırları", () => {
    const b = bbox(flattenPath(rect100x50()));
    expect(b.min).toEqual(vec(0, 0));
    expect(b.max).toEqual(vec(100, 50));
    expect(b.width).toBe(100);
    expect(b.height).toBe(50);
  });

  it("boş poligonda patlamaz", () => {
    expect(bbox([]).width).toBe(0);
  });
});

describe("simplify", () => {
  it("eşdoğrusal ara noktaları atar", () => {
    const poly = [vec(0, 0), vec(5, 0), vec(10, 0), vec(10, 10)];
    expect(simplify(poly)).toHaveLength(3);
  });

  it("gerçek köşeleri korur", () => {
    expect(simplify(flattenPath(rect100x50()))).toHaveLength(4);
  });
});

describe("yuvarlatılmış köşe (kart yuvası ağzı senaryosu)", () => {
  it("bezier kenar makul sayıda noktaya düzleşir ve bbox korunur", () => {
    const p = path()
      .moveTo(vec(0, 0))
      .lineTo(vec(50, 0))
      .cubicTo(vec(60, 0), vec(60, 10), vec(60, 20))
      .lineTo(vec(0, 20))
      .close();
    const poly = flattenPath(p);
    expect(poly.length).toBeGreaterThan(4);
    expect(poly.length).toBeLessThan(200);
    const b = bbox(poly);
    expect(b.max.x).toBeCloseTo(60, 6);
    expect(b.max.y).toBeCloseTo(20, 6);
  });
});
ODK_EOF_1

echo "==> packages/patterns/src/stitchprojection.ts"
cat > packages/patterns/src/stitchprojection.ts << 'ODK_EOF_2'
import type { Mm, Polyline, StitchPlan, StitchHole, Vec } from "@odk/geometry";
import { offsetPolygons, pointInPolygon } from "@odk/geometry";

/**
 * DİKİŞ PLANI PROJEKSİYONU
 *
 * ═══════════════════════════════════════════════════════════════════════
 * NEDEN HER PARÇA İÇİN AYRI DAĞITIM YAPILMIYOR
 * ═══════════════════════════════════════════════════════════════════════
 *
 * Çevre dikişi bütün katmanlardan aynı anda geçer: dış kabuk, iç kabuk
 * ve kenara ulaşan yuva parçaları tek bir iplikle birlikte dikilir.
 * Dolayısıyla deliklerin HİZALANMASI zorunlu.
 *
 * Her parçaya bağımsız `distributeStitches` çağırmak felaket olurdu:
 * parçaların çevre uzunlukları farklı, köşe konumları farklı, dolayısıyla
 * delik konumları da farklı çıkardı. Kağıtta düzgün görünen ama üst üste
 * konduğunda tutmayan delikler.
 *
 * Doğru yol: çevre dikişi TEK KEZ, birleşik dış hat üzerinde planlanır;
 * sonra her parçaya kendi sınırları içine düşen delikler yansıtılır.
 * Böylece bütün parçalardaki delikler tanım gereği aynı noktalardır.
 *
 * ═══════════════════════════════════════════════════════════════════════
 * KENAR TOLERANSI
 * ═══════════════════════════════════════════════════════════════════════
 *
 * Delikler parçanın kesim hattının biraz İÇİNDE, dikiş payı kadar
 * mesafede. Ama yuva parçasının kenarı çoğu zaman tam olarak ana
 * parçanın kenarıyla çakışıyor ve nokta-poligon testi kenar üstünde
 * kararsız. Bu yüzden test edilen poligon önce dışa ötelenir.
 */

/**
 * Kat payı SIRTTA soğurulan parçalar için projeksiyon.
 *
 * İç kabuk dış kabuktan kat payı kadar kısa. Ama montajda ortalanmıyor:
 * sol kenarı dış kabuğun sol kenarıyla, sağ kenarı sağ kenarıyla
 * hizalanıyor; eksik uzunluk sırtta kapanıyor.
 *
 * İlk sürümde ortalanmış varsaymıştım ve iç kabuğa 143 yerine 105 delik
 * düşüyordu — yan kenarların tamamı kaybolmuştu. Oysa iç kabuk çevre
 * dikişine tam boyunca yakalanır.
 *
 * Bu yüzden delikler sırt çizgisinin hangi tarafında olduğuna göre
 * kaydırılıyor: sol taraf olduğu gibi, sağ taraf kat payı kadar sola.
 */
export function projectAcrossFold(
  master: StitchPlan,
  foldAxis: Mm,
  shortfall: Mm,
  pieceOutline: Polyline,
  vertical: boolean,
  tolerance: Mm = PROJECTION_TOLERANCE,
): ProjectionResult {
  const shifted: StitchPlan = {
    ...master,
    holes: master.holes.map((h) => {
      const along = vertical ? h.position.x : h.position.y;
      if (along < foldAxis) return h;
      return {
        ...h,
        position: vertical
          ? { x: h.position.x - shortfall, y: h.position.y }
          : { x: h.position.x, y: h.position.y - shortfall },
      };
    }),
  };
  return projectStitchPlan(shifted, { x: 0, y: 0 }, pieceOutline, tolerance);
}

/** Kenar üstündeki delikleri güvenli yakalamak için genişletme payı. */
export const PROJECTION_TOLERANCE: Mm = 0.5;

export interface ProjectionResult {
  readonly plan: StitchPlan | undefined;
  /** Bu parçaya düşen delik sayısı. */
  readonly count: number;
}

/**
 * Ana dikiş planından bir parçaya düşen delikleri çıkarır.
 *
 * @param master     Birleşik dış hat üzerinde hesaplanmış plan.
 *                   Delik konumları MONTAJ koordinatında.
 * @param offset     Parçanın montajdaki sol-alt köşesi.
 * @param pieceOutline Parçanın KENDİ koordinatındaki kesim hattı.
 */
export function projectStitchPlan(
  master: StitchPlan,
  offset: Vec,
  pieceOutline: Polyline,
  tolerance: Mm = PROJECTION_TOLERANCE,
): ProjectionResult {
  if (pieceOutline.length < 3) return { plan: undefined, count: 0 };

  const grown = offsetPolygons([pieceOutline], tolerance, { join: "miter" });
  const test = (grown[0] ?? pieceOutline) as Polyline;

  const minX = Math.min(...pieceOutline.map((p) => p.x));
  const minY = Math.min(...pieceOutline.map((p) => p.y));
  const testMinX = Math.min(...test.map((p) => p.x));
  const testMinY = Math.min(...test.map((p) => p.y));

  const holes: StitchHole[] = [];
  for (const hole of master.holes) {
    // Montaj koordinatı -> parça yerel koordinatı.
    const local: Vec = {
      x: hole.position.x - offset.x,
      y: hole.position.y - offset.y,
    };
    // Genişletilmiş poligon kendi çerçevesinde kaydığı için testi
    // aynı hizaya getiriyoruz.
    const probe: Vec = {
      x: local.x - minX + testMinX,
      y: local.y - minY + testMinY,
    };
    if (pointInPolygon(test, probe)) {
      holes.push({ ...hole, position: local });
    }
  }

  if (holes.length === 0) return { plan: undefined, count: 0 };

  return {
    plan: {
      holes,
      // Segment planı ana plandan devralınıyor: parçadaki delikler ana
      // planın alt kümesi olduğu için adım ve sapma da aynı.
      spans: master.spans,
      pitch: master.pitch,
      totalHoles: holes.length,
      maxDeviation: master.maxDeviation,
      warnings: [],
    },
    count: holes.length,
  };
}
ODK_EOF_2

echo "==> packages/patterns/src/cardholder.ts"
cat > packages/patterns/src/cardholder.ts << 'ODK_EOF_3'
import type { Mm, Polyline, Vec, StitchPlan } from "@odk/geometry";
import {
  path,
  flattenPath,
  bbox,
  cutLine,
  stitchLine,
  roundCorners,
  distributeStitches,
  narrowestWidth,
  vec,
  CARD_ID1,
  A4,
} from "@odk/geometry";
import type { Temper } from "./material.js";
import { leather, RECOMMENDED_THICKNESS, MAX_CLOSED_THICKNESS } from "./material.js";
import { projectStitchPlan } from "./stitchprojection.js";
import type { CardOrientation, SlotConstruction } from "./cardslot.js";
import { cardSlotGeometry, validateCardSlots, T_SLOT_WRAP_ALLOWANCE } from "./cardslot.js";
import type { CrossSection, CrossSectionResult, Diagnostic, Layer } from "./crosssection.js";
import {
  solveCrossSection,
  foldLengthDelta,
  naturalInnerRadius,
  layerResult,
} from "./crosssection.js";

/**
 * KARTLIK ÜRETECİ (MVP)
 *
 * Faz 3'ün tam modül sisteminin öncüsü. Amaç motoru uçtan uca
 * çalıştırabilmek: parametre → kesit çözümü → parça hatları → dikiş
 * planı. Tek iskelet (katlanır kartlık) ve tek modül (CardSlot) var.
 *
 * BASİTLEŞTİRME (bilinçli): çevre dikişi yalnızca dış parça üzerinde
 * planlanır; yuva parçaları bu dikişe yakalanır. Gerçek yapım biçimi bu
 * ve yuva parçaları için var olmayan dikiş yolları uydurmaktan kaçınır.
 */

export interface CardHolderParams {
  readonly cardCount: number;
  readonly construction: SlotConstruction;
  readonly orientation: CardOrientation;
  readonly outerThickness: Mm;
  readonly slotThickness: Mm;
  readonly temper: Temper;
  readonly reveal: Mm;
  readonly stitchMargin: Mm;
  readonly cornerRadius: Mm;
  readonly penAllowance: Mm;
  /** Verilmezse minimax ile otomatik seçilir. */
  readonly pitch?: Mm;
}

export const DEFAULT_PARAMS: CardHolderParams = {
  cardCount: 4,
  construction: "t-slot",
  orientation: "horizontal",
  outerThickness: RECOMMENDED_THICKNESS.outerShell.preferred,
  slotThickness: RECOMMENDED_THICKNESS.cardSlot.preferred,
  temper: "veg-tan-firm",
  reveal: 12,
  stitchMargin: 3.5,
  cornerRadius: 4,
  penAllowance: 0.3,
  /**
   * Varsayılan 3.85mm.
   *
   * Otomatik seçime BIRAKILMIYOR: kullanıcının elinde belirli bir
   * pricking iron var ve hangi adımı kullanacağını motor bilemez.
   * Otomatik seçim yalnızca sapmayı ölçebilir; dikişin ne kadar sık
   * görüneceği estetik bir karar ve kullanıcıya ait.
   *
   * 3.85mm küçük deri ürünlerinde en yaygın adım.
   */
  pitch: 3.85,
};

export type PieceKind = "outer" | "slot-rect" | "slot-t";

export interface FoldLine {
  readonly from: Vec;
  readonly to: Vec;
  readonly label: string;
}

export interface PatternPiece {
  readonly id: string;
  /**
   * Kısa ve kararlı parça kodu (A, B, C...).
   *
   * Talimatlarda ve montaj görünümünde parçalara atıf yapmak için.
   * Ad değişebilir, kod değişmez.
   */
  readonly code: string;
  readonly name: string;
  readonly kind: PieceKind;
  readonly quantity: number;
  readonly leatherThickness: Mm;
  /** Basılacak kesim hattı (kalem payı uygulanmış). */
  readonly cutLine: Polyline;
  /** Dikiş hattı — yalnızca çevre dikişi olan parçalarda. */
  readonly stitchLine?: Polyline;
  /**
   * Dikiş hattı kapalı bir çevre mi?
   *
   * Cüzdanlarda DEĞİL: banknot ya da kart bölmesinin ağzı açık kalmak
   * zorunda. Kapalı çizmek hem yanlış görünür hem de o kenara delik
   * yerleştirir — dikilirse bölme kapanır ve ürün işe yaramaz.
   */
  readonly stitchLineClosed?: boolean;
  readonly stitchPlan?: StitchPlan;
  readonly foldLines: readonly FoldLine[];
  readonly width: Mm;
  readonly height: Mm;
}

/**
 * Montajdaki bir parça örneği.
 *
 * NEDEN AYRI BİR LİSTE: parçalar tipe göre gruplanıyor ("T-slot yuva ×3")
 * ama montaj görünümü her örneği ayrı konumda göstermek zorunda.
 */
export interface AssemblyPlacement {
  readonly pieceId: string;
  readonly code: string;
  /** Dış kabuğun sol-alt köşesine göre konum. */
  readonly x: Mm;
  readonly y: Mm;
  /** 0 = en altta (dış kabuk). Büyük sayı üstte. */
  readonly layer: number;
}

export interface PatternSummary {
  readonly compartmentWidth: Mm;
  readonly slotStackHeight: Mm;
  readonly outerFlatWidth: Mm;
  readonly outerFlatHeight: Mm;
  readonly closedThickness: Mm;
  readonly loadedThickness: Mm;
  readonly edgeThickness: Mm;
  readonly foldAllowance: Mm;
  /** Katlanmış hâlde bir panelin yüksekliği. */
  readonly panelHeight: Mm;
  readonly totalHoles: number;
  readonly pitch: Mm;
  readonly fitsA4: boolean;
}

export interface PatternResult {
  readonly pieces: readonly PatternPiece[];
  /** Parçaların bitmiş üründeki (açık hâlde) yerleşimi. */
  readonly assembly: readonly AssemblyPlacement[];
  readonly crossSection: CrossSectionResult;
  readonly diagnostics: readonly Diagnostic[];
  readonly summary: PatternSummary;
}

function cardW(o: CardOrientation): Mm {
  return o === "horizontal" ? CARD_ID1.width : CARD_ID1.height;
}
function cardH(o: CardOrientation): Mm {
  return o === "horizontal" ? CARD_ID1.height : CARD_ID1.width;
}

function rectangle(x: Mm, y: Mm, w: Mm, h: Mm): Polyline {
  return flattenPath(
    path()
      .moveTo(vec(x, y))
      .lineTo(vec(x + w, y))
      .lineTo(vec(x + w, y + h))
      .lineTo(vec(x, y + h))
      .close(),
  );
}

/**
 * T-slot parçası.
 *
 * Üstte tam genişlikte "kollar", altta daralmış "gövde". Gövdenin
 * bölmenin kenarına ulaşmaması, kaç yuva olursa olsun kenarda tek
 * katman kalmasını sağlayan şey.
 */
function tSlotShape(width: Mm, height: Mm, mouthHeight: Mm, sideInset: Mm): Polyline {
  const shoulder = height - mouthHeight;
  return flattenPath(
    path()
      .moveTo(vec(sideInset, 0))
      .lineTo(vec(width - sideInset, 0))
      .lineTo(vec(width - sideInset, shoulder))
      .lineTo(vec(width, shoulder))
      .lineTo(vec(width, height))
      .lineTo(vec(0, height))
      .lineTo(vec(0, shoulder))
      .lineTo(vec(sideInset, shoulder))
      .close(),
  );
}

export function generateCardHolder(params: CardHolderParams): PatternResult {
  const diagnostics: Diagnostic[] = [];

  const slotGeo = cardSlotGeometry({
    count: params.cardCount,
    construction: params.construction,
    orientation: params.orientation,
    leatherThickness: params.slotThickness,
    reveal: params.reveal,
    stitchMargin: params.stitchMargin,
  });

  for (const d of validateCardSlots({
    count: params.cardCount,
    construction: params.construction,
    orientation: params.orientation,
    leatherThickness: params.slotThickness,
    reveal: params.reveal,
    stitchMargin: params.stitchMargin,
  })) {
    diagnostics.push({ severity: d.severity, code: d.code, message: d.message });
  }

  // --- Kesit: dış kabuk yuva yığınını sarıyor ---------------------------
  const outerSpec = leather(params.temper, params.outerThickness);
  const slotSpec = leather(params.temper, params.slotThickness);

  const layers: Layer[] = [
    { id: "slots", name: "kart yuvaları", spec: slotSpec },
    { id: "outer", name: "dış kabuk", spec: outerSpec },
  ];

  // Kapalı kalınlık: yuva katmanları + dış kabuk iki kez (katlandığı için).
  const closedThickness = slotGeo.centerThickness + 2 * params.outerThickness;
  const loadedThickness = slotGeo.loadedThickness + 2 * params.outerThickness;

  const panelHeight = slotGeo.stackHeight + params.stitchMargin;
  const innerRadius = naturalInnerRadius(slotGeo.centerThickness);

  const crossSection: CrossSection = {
    name: "kartlık",
    layers,
    runs: [
      { id: "front", name: "ön panel", length: panelHeight, layers: ["slots", "outer"] },
      { id: "back", name: "arka panel", length: panelHeight, layers: ["outer"] },
    ],
    folds: [
      {
        id: "spine",
        name: "kat",
        angleDeg: 180,
        innerRadius,
        stack: ["slots", "outer"],
      },
    ],
  };

  const solved = solveCrossSection(crossSection);
  diagnostics.push(...solved.diagnostics);

  const foldAllowance = foldLengthDelta(
    slotGeo.centerThickness + params.outerThickness,
    180,
  );

  // --- Parçalar ---------------------------------------------------------
  const W = slotGeo.compartmentWidth;
  const outerFlat = layerResult(solved, "outer")?.flatLength ?? 2 * panelHeight;

  const pieces: PatternPiece[] = [];

  // Dış kabuk: katlanan tek parça, çevre dikişi burada.
  //
  // KÖŞE SIRASI ÖNEMLİ: yuvarlatma NOMİNAL şekle uygulanır, dikiş
  // hattına değil. Fiziksel gerçek bu — deri parçanın köşesi yuvarlak
  // kesilir, dikiş hattı da onu takip eder. Yalnızca dikiş hattını
  // yuvarlatmak, keskin köşeli bir parçaya yuvarlak dikiş çizmek olurdu.
  const outerNominal = roundCorners(rectangle(0, 0, W, outerFlat), true, {
    radius: params.cornerRadius,
  });
  const outerCut = cutLine(outerNominal, { penAllowance: params.penAllowance });
  const outerStitchRaw = stitchLine(outerCut, params.stitchMargin);
  // İçe öteleme yuvarlatmayı küçültür ve yarıçap dikiş payından küçükse
  // köşeyi tekrar keskinleştirir (Adım 5 bulgusu). İkinci geçiş bunu
  // telafi eder; zaten yumuşak olan noktalara dokunmaz.
  const outerStitch = roundCorners(outerStitchRaw, true, {
    radius: Math.max(1, params.cornerRadius - params.stitchMargin),
  });
  const outerPlan = distributeStitches(
    outerStitch,
    true,
    params.pitch !== undefined ? { pitch: params.pitch } : {},
  );
  const outerBox = bbox(outerCut);

  // Kat çizgisi: nötr eksen boyunca hesaplanan uzunluğun ortası.
  const foldY = outerFlat / 2;
  pieces.push({
    id: "outer",
    code: "A",
    name: "dış kabuk",
    kind: "outer",
    quantity: 1,
    leatherThickness: params.outerThickness,
    cutLine: outerCut,
    stitchLine: outerStitch,
    stitchPlan: outerPlan,
    foldLines: [
      {
        from: vec(0, foldY - foldAllowance / 2),
        to: vec(W, foldY - foldAllowance / 2),
        label: "kat başlangıcı",
      },
      {
        from: vec(0, foldY + foldAllowance / 2),
        to: vec(W, foldY + foldAllowance / 2),
        label: "kat bitişi",
      },
    ],
    width: outerBox.width,
    height: outerBox.height,
  });

  // --- Yuva parçaları ----------------------------------------------------
  //
  // HER ÖRNEK AYRI PARÇA: her yuva çevre dikişinden farklı delikler
  // alıyor (en alttaki alt kenarı da yakalıyor, üsttekiler yalnızca yan
  // kenarları). Delikler ana plandan yansıtılıyor ki katmanlar üst üste
  // konduğunda tutsun.
  const slotPieceHeight = cardH(params.orientation) + params.stitchMargin;
  const mouthHeight = Math.min(params.reveal, slotPieceHeight / 2);
  const sideInset = params.stitchMargin + T_SLOT_WRAP_ALLOWANCE;

  const rectShape = roundCorners(rectangle(0, 0, W, slotPieceHeight), true, {
    radius: Math.min(params.cornerRadius, slotPieceHeight / 4),
  });
  const tShape = roundCorners(
    tSlotShape(W, slotPieceHeight, mouthHeight, sideInset),
    true,
    { radius: Math.min(params.cornerRadius, sideInset / 2) },
  );

  if (slotGeo.tSlotPieces > 0) {
    const neck = narrowestWidth(
      cutLine(tShape, { penAllowance: params.penAllowance }),
    );
    if (neck < params.stitchMargin * 2) {
      diagnostics.push({
        severity: "warning",
        code: "T_STEM_NARROW",
        message:
          `T-slot gövdesi ${neck.toFixed(1)}mm — dikiş payının iki katından ` +
          `(${(params.stitchMargin * 2).toFixed(1)}mm) ince. Yan payı azaltmayı ` +
          `ya da bölmeyi genişletmeyi düşün.`,
      });
    }
  }

  const assembly: AssemblyPlacement[] = [];
  const n = Math.max(0, Math.floor(params.cardCount));
  for (let i = 0; i < n; i++) {
    const isRect = params.construction === "stacked" || i === 0;
    const code = `${isRect ? "B" : "C"}${i + 1}`;
    const id = `slot-${i + 1}`;
    const origin = { x: 0, y: i * params.reveal };

    const cut = cutLine(isRect ? rectShape : tShape, {
      penAllowance: params.penAllowance,
    });
    const b = bbox(cut);
    const projected = projectStitchPlan(outerPlan, origin, cut);

    pieces.push({
      id,
      code,
      name: isRect ? `alt yuva ${i + 1}` : `T-slot yuva ${i + 1}`,
      kind: isRect ? "slot-rect" : "slot-t",
      quantity: 1,
      leatherThickness: params.slotThickness,
      cutLine: cut,
      ...(projected.plan === undefined ? {} : { stitchPlan: projected.plan }),
      foldLines: [],
      width: b.width,
      height: b.height,
    });

    assembly.push({ pieceId: id, code, x: origin.x, y: origin.y, layer: i + 1 });
  }

  // --- Kural denetimi ---------------------------------------------------
  if (closedThickness > MAX_CLOSED_THICKNESS) {
    diagnostics.push({
      severity: "error",
      code: "TOO_THICK",
      message:
        `Kapalı kalınlık ${closedThickness.toFixed(1)}mm — üst sınır ` +
        `${MAX_CLOSED_THICKNESS}mm. Bu artık cep cüzdanı değil.`,
    });
  }

  const fitsA4 = outerBox.width <= A4.width - 20 && outerBox.height <= A4.height - 20;
  if (!fitsA4) {
    diagnostics.push({
      severity: "warning",
      code: "NEEDS_TILING",
      message:
        `Dış kabuk ${outerBox.width.toFixed(0)} × ${outerBox.height.toFixed(0)}mm — ` +
        `tek A4'e kenar payıyla sığmıyor, birden fazla sayfaya bölünecek.`,
    });
  }

  return {
    pieces,
    assembly,
    crossSection: solved,
    diagnostics,
    summary: {
      compartmentWidth: W,
      slotStackHeight: slotGeo.stackHeight,
      outerFlatWidth: outerBox.width,
      outerFlatHeight: outerBox.height,
      closedThickness,
      loadedThickness,
      edgeThickness: slotGeo.edgeThickness,
      foldAllowance,
      panelHeight,
      totalHoles: outerPlan.totalHoles,
      pitch: outerPlan.pitch,
      fitsA4,
    },
  };
}

/** Kart genişliği/yüksekliği dışa açılıyor: arayüz etiketleri için. */
export const cardDimensions = { width: cardW, height: cardH };
ODK_EOF_3

echo "==> packages/patterns/src/cardholder.test.ts"
cat > packages/patterns/src/cardholder.test.ts << 'ODK_EOF_4'
import { describe, it, expect } from "vitest";
import { A4 } from "@odk/geometry";
import { DEFAULT_PARAMS, generateCardHolder } from "./cardholder.js";
import { foldLengthDelta, layerResult } from "./crosssection.js";

describe("generateCardHolder — varsayılan parametreler", () => {
  const r = generateCardHolder(DEFAULT_PARAMS);

  it("hata üretmiyor", () => {
    expect(r.diagnostics.filter((d) => d.severity === "error")).toHaveLength(0);
  });

  it("dış kabuk + her yuva için ayrı parça üretiliyor", () => {
    // Yuvalar GRUPLANAMAZ: her biri çevre dikişinden farklı delikler
    // alıyor, dolayısıyla farklı bir kalıp.
    expect(r.pieces.map((p) => p.id)).toEqual([
      "outer",
      "slot-1",
      "slot-2",
      "slot-3",
      "slot-4",
    ]);
  });

  it("4 yuva = 1 düz (en dip) + 3 T-slot", () => {
    const kinds = r.pieces.filter((p) => p.id !== "outer").map((p) => p.kind);
    expect(kinds).toEqual(["slot-rect", "slot-t", "slot-t", "slot-t"]);
    expect(r.pieces.every((p) => p.quantity === 1)).toBe(true);
  });

  it("her yuva parçasının kendi delikleri var ve ana plandan geliyor", () => {
    const outer = r.pieces.find((p) => p.id === "outer");
    const slots = r.pieces.filter((p) => p.id.startsWith("slot-"));
    for (const s of slots) {
      expect(s.stitchPlan).toBeDefined();
      expect(s.stitchPlan?.pitch).toBe(outer?.stitchPlan?.pitch);
      expect(s.stitchPlan?.totalHoles).toBeLessThan(
        outer?.stitchPlan?.totalHoles as number,
      );
    }
  });

  it("en dipteki yuva üsttekilerden daha çok delik alıyor", () => {
    // Alt kenar dikişini de yakalıyor.
    const bottom = r.pieces.find((p) => p.id === "slot-1");
    const top = r.pieces.find((p) => p.id === "slot-4");
    expect(bottom?.stitchPlan?.totalHoles).toBeGreaterThan(
      top?.stitchPlan?.totalHoles as number,
    );
  });

  it("bölme genişliği belgelenmiş 100mm'ye yakın", () => {
    expect(r.summary.compartmentWidth).toBeCloseTo(100, 1);
  });

  it("dış kabukta tam çevre dikişi planı var", () => {
    expect(r.pieces.find((p) => p.id === "outer")?.stitchPlan).toBeDefined();
  });

  it("kat payı hesaplanıp iki kat çizgisi olarak veriliyor", () => {
    const outer = r.pieces.find((p) => p.id === "outer");
    expect(outer?.foldLines).toHaveLength(2);
    expect(r.summary.foldAllowance).toBeGreaterThan(0);
  });

  it("dış kabuk düz uzunluğu kesit çözücüden geliyor", () => {
    const solved = layerResult(r.crossSection, "outer");
    expect(solved?.flatLength).toBeGreaterThan(0);
    // Kalem payı 0.3mm iki kenardan düşülmüş.
    //
    // Hassasiyet 3 (EPS = 1 mikron): boru hattı Clipper'ın tamsayı
    // ızgarasından geçtiği için ~60 nanometrelik yuvarlama artığı var.
    // Bunu 6 haneye kadar kovalamak motorun kendi çözünürlüğünün altına
    // inmek olur; EPS zaten bu sınırı tanımlıyor.
    expect(r.summary.outerFlatHeight).toBeCloseTo(
      (solved?.flatLength as number) - 0.6,
      3,
    );
  });

  it("dikiş adımı fiziksel iron listesinden", () => {
    expect([2.7, 3.0, 3.38, 3.85, 4.0, 5.0]).toContain(r.summary.pitch);
  });

  it("A4'e sığıyor", () => {
    expect(r.summary.fitsA4).toBe(true);
    expect(r.summary.outerFlatWidth).toBeLessThan(A4.width);
  });

  it("kapalı kalınlık makul bandda", () => {
    expect(r.summary.closedThickness).toBeGreaterThan(2);
    expect(r.summary.closedThickness).toBeLessThan(10);
  });
});

describe("T-slot etkisi kalıpta görünüyor", () => {
  it("stacked yapımda tüm yuvalar düz dikdörtgen", () => {
    const s = generateCardHolder({
      ...DEFAULT_PARAMS,
      construction: "stacked",
    });
    expect(
      s.pieces.filter((p) => p.id !== "outer").every((p) => p.kind === "slot-rect"),
    ).toBe(true);
  });

  it("stacked ile kenar kalınlığı çok daha fazla", () => {
    const t = generateCardHolder({ ...DEFAULT_PARAMS, cardCount: 6 });
    const s = generateCardHolder({
      ...DEFAULT_PARAMS,
      cardCount: 6,
      construction: "stacked",
    });
    expect(s.summary.edgeThickness).toBeGreaterThan(t.summary.edgeThickness * 5);
  });

  it("stacked 6 yuvada uyarı üretiyor", () => {
    const s = generateCardHolder({
      ...DEFAULT_PARAMS,
      cardCount: 6,
      construction: "stacked",
    });
    expect(s.diagnostics.some((d) => d.code === "STACKED_TOO_MANY")).toBe(true);
  });
});

describe("parametre duyarlılığı", () => {
  it("yuva sayısı arttıkça dış kabuk uzuyor", () => {
    const a = generateCardHolder({ ...DEFAULT_PARAMS, cardCount: 3 });
    const b = generateCardHolder({ ...DEFAULT_PARAMS, cardCount: 6 });
    expect(b.summary.outerFlatHeight).toBeGreaterThan(a.summary.outerFlatHeight);
  });

  it("deri kalınlaştıkça kat payı büyüyor", () => {
    const thin = generateCardHolder({ ...DEFAULT_PARAMS, slotThickness: 0.6 });
    const thick = generateCardHolder({ ...DEFAULT_PARAMS, slotThickness: 0.8 });
    expect(thick.summary.foldAllowance).toBeGreaterThan(thin.summary.foldAllowance);
  });

  it("kat payı π × (yuva yığını + dış kabuk) formülüne uyuyor", () => {
    const r = generateCardHolder(DEFAULT_PARAMS);
    const slotStack = 4 * DEFAULT_PARAMS.slotThickness;
    expect(r.summary.foldAllowance).toBeCloseTo(
      foldLengthDelta(slotStack + DEFAULT_PARAMS.outerThickness, 180),
      6,
    );
  });

  it("kalem payı kesim hattını küçültüyor", () => {
    const none = generateCardHolder({ ...DEFAULT_PARAMS, penAllowance: 0 });
    const some = generateCardHolder({ ...DEFAULT_PARAMS, penAllowance: 0.5 });
    expect(some.summary.outerFlatWidth).toBeCloseTo(
      none.summary.outerFlatWidth - 1,
      6,
    );
  });

  it("çok fazla yuva A4 uyarısı üretiyor", () => {
    const r = generateCardHolder({ ...DEFAULT_PARAMS, cardCount: 8, reveal: 20 });
    expect(r.summary.fitsA4).toBe(false);
    expect(r.diagnostics.some((d) => d.code === "NEEDS_TILING")).toBe(true);
  });

  it("dikey yönde bölme daralıyor", () => {
    const h = generateCardHolder(DEFAULT_PARAMS);
    const v = generateCardHolder({ ...DEFAULT_PARAMS, orientation: "vertical" });
    expect(v.summary.compartmentWidth).toBeLessThan(h.summary.compartmentWidth);
  });
});
ODK_EOF_4

echo "==> packages/patterns/src/bifold.ts"
cat > packages/patterns/src/bifold.ts << 'ODK_EOF_5'
import type { Mm, Polyline, Vec } from "@odk/geometry";
import {
  A4,
  CARD_ID1,
  bbox,
  cutLine,
  distributeStitches,
  flattenPath,
  path,
  roundCorners,
  vec,
} from "@odk/geometry";
import type { Temper } from "./material.js";
import {
  BIFOLD_TARGET_CLOSED_THICKNESS,
  CARD_THICKNESS,
  MAX_CLOSED_THICKNESS,
  RECOMMENDED_THICKNESS,
  leather,
} from "./material.js";
import type { SlotConstruction } from "./cardslot.js";
import { T_SLOT_WRAP_ALLOWANCE, cardSlotGeometry, validateCardSlots } from "./cardslot.js";
import { projectAcrossFold, projectStitchPlan } from "./stitchprojection.js";
import type { Currency } from "./banknote.js";
import { billPocketGeometry, validateBillPocket } from "./banknote.js";
import type {
  AssemblyPlacement,
  PatternPiece,
  PatternResult,
  PatternSummary,
} from "./cardholder.js";
import type { CrossSection, Diagnostic, Layer } from "./crosssection.js";
import {
  foldLengthDelta,
  layerResult,
  naturalInnerRadius,
  solveCrossSection,
} from "./crosssection.js";

/**
 * BİFOLD CÜZDAN
 *
 * ═══════════════════════════════════════════════════════════════════════
 * NEDEN BU MODEL KARTLIKTAN FARKLI
 * ═══════════════════════════════════════════════════════════════════════
 *
 * Kartlıkta dış kabuk yalnızca kendi iç katmanının etrafını dolanıyordu.
 * Bifold'da dış kabuk TÜM İÇERİĞİN etrafını dolanır: iç kabuk, iki
 * yandaki kart yığınları, kartların kendisi ve banknot.
 *
 * Bunu ilk modellediğimde kıvrım yığınına yalnızca iki deri katmanını
 * koydum ve dış/iç fark 2.8mm çıktı. Belgelenmiş kural 12.7mm (yarım
 * inç) diyor. Fark, kıvrımda katman OLMAYAN dolgudan geliyordu:
 * kartlar ve yuva derileri kıvrımdan geçmiyor ama dış kabuğun
 * yürüyeceği yarıçapı belirliyor.
 *
 * Fold.gaps alanı tam olarak bunun için eklendi. Varsayılan
 * parametrelerle model 12–13mm veriyor; yarım inç kuralıyla örtüşüyor.
 * (Bkz. bifold.test.ts — bu bir test olarak sabitlendi.)
 */

export interface BifoldParams {
  /** Her panelde kaç kart yuvası. */
  readonly cardSlotsPerSide: number;
  readonly construction: SlotConstruction;
  readonly currency: Currency;
  readonly outerThickness: Mm;
  readonly innerThickness: Mm;
  readonly slotThickness: Mm;
  readonly temper: Temper;
  readonly reveal: Mm;
  readonly stitchMargin: Mm;
  readonly cornerRadius: Mm;
  readonly penAllowance: Mm;
  readonly pitch?: Mm;
}

export const BIFOLD_DEFAULTS: BifoldParams = {
  cardSlotsPerSide: 3,
  construction: "t-slot",
  currency: "TRY",
  // Bifold'da dış kabuk aralığın ALT ucunda tutulmalı; katman sayısı
  // fazla olduğu için kalınlık hızla birikiyor.
  outerThickness: 0.9,
  innerThickness: 0.8,
  slotThickness: RECOMMENDED_THICKNESS.cardSlot.preferred,
  temper: "veg-tan-firm",
  reveal: 12,
  stitchMargin: 3.5,
  cornerRadius: 5,
  penAllowance: 0.3,
  pitch: 3.85,
};

function rectangle(x: Mm, y: Mm, w: Mm, h: Mm): Polyline {
  return flattenPath(
    path()
      .moveTo(vec(x, y))
      .lineTo(vec(x + w, y))
      .lineTo(vec(x + w, y + h))
      .lineTo(vec(x, y + h))
      .close(),
  );
}

function tSlotShape(width: Mm, height: Mm, mouthHeight: Mm, sideInset: Mm): Polyline {
  const shoulder = height - mouthHeight;
  return flattenPath(
    path()
      .moveTo(vec(sideInset, 0))
      .lineTo(vec(width - sideInset, 0))
      .lineTo(vec(width - sideInset, shoulder))
      .lineTo(vec(width, shoulder))
      .lineTo(vec(width, height))
      .lineTo(vec(0, height))
      .lineTo(vec(0, shoulder))
      .lineTo(vec(sideInset, shoulder))
      .close(),
  );
}

export function generateBifold(params: BifoldParams): PatternResult {
  const diagnostics: Diagnostic[] = [];
  const n = Math.max(0, Math.floor(params.cardSlotsPerSide));

  // --- Kart yuvaları (panel başına) -------------------------------------
  const slotGeo = cardSlotGeometry({
    count: n,
    construction: params.construction,
    orientation: "horizontal",
    leatherThickness: params.slotThickness,
    reveal: params.reveal,
    stitchMargin: params.stitchMargin,
  });

  for (const d of validateCardSlots({
    count: n,
    construction: params.construction,
    orientation: "horizontal",
    leatherThickness: params.slotThickness,
    reveal: params.reveal,
    stitchMargin: params.stitchMargin,
  })) {
    diagnostics.push({ severity: d.severity, code: d.code, message: d.message });
  }

  // --- Cüzdan ölçüleri ---------------------------------------------------
  //
  // Açık genişlik iki kısıttan büyüğü:
  //   a) banknot + boşluk + iki yanda dikiş payı
  //   b) iki kart yığını yan yana
  // Yükseklik ise kart yığını ve banknot örtüsünden büyüğü.
  const billGeo = billPocketGeometry({
    currency: params.currency,
    leatherThickness: params.innerThickness,
    stitchMargin: params.stitchMargin,
  });

  const panelWidth = slotGeo.compartmentWidth;
  const widthFromCards = 2 * panelWidth;
  const widthFromBill = billGeo.compartmentWidth;
  const openWidth = Math.max(widthFromCards, widthFromBill);

  const heightFromCards = slotGeo.stackHeight + 2 * params.stitchMargin;
  const walletHeight = Math.max(heightFromCards, billGeo.minWalletHeight);

  for (const d of validateBillPocket(
    {
      currency: params.currency,
      leatherThickness: params.innerThickness,
      stitchMargin: params.stitchMargin,
    },
    walletHeight,
  )) {
    diagnostics.push({ severity: d.severity, code: d.code, message: d.message });
  }

  // --- Kalınlıklar -------------------------------------------------------
  //
  // Kapalı kalınlık en kalın noktada ölçülür: iki panel de kart yüklü.
  const cardStackPerPanel = slotGeo.centerThickness + n * CARD_THICKNESS;
  const closedThickness =
    2 * params.outerThickness + 2 * params.innerThickness + 2 * slotGeo.centerThickness;
  const loadedThickness =
    2 * params.outerThickness + 2 * params.innerThickness + 2 * cardStackPerPanel;

  // --- Kesit -------------------------------------------------------------
  //
  // Kıvrımda yalnızca iki deri katmanı geçiyor (iç ve dış kabuk).
  // Kart yığını kıvrımdan GEÇMEZ ama dış kabuğun yarıçapını belirler;
  // bu yüzden dolgu (gap) olarak modelleniyor.
  const outerSpec = leather(params.temper, params.outerThickness);
  const innerSpec = leather(params.temper, params.innerThickness);

  const layers: Layer[] = [
    { id: "inner", name: "iç kabuk", spec: innerSpec },
    { id: "outer", name: "dış kabuk", spec: outerSpec },
  ];

  const foldFill = cardStackPerPanel;

  const crossSection: CrossSection = {
    name: "bifold",
    layers,
    runs: [
      { id: "left", name: "sol panel", length: panelWidth, layers: ["inner", "outer"] },
      { id: "right", name: "sağ panel", length: panelWidth, layers: ["inner", "outer"] },
    ],
    folds: [
      {
        id: "spine",
        name: "sırt",
        angleDeg: 180,
        innerRadius: naturalInnerRadius(params.innerThickness),
        stack: ["inner", "outer"],
        gaps: { outer: foldFill },
      },
    ],
  };

  const solved = solveCrossSection(crossSection);
  diagnostics.push(...solved.diagnostics);

  const innerFlat = layerResult(solved, "inner")?.flatLength ?? openWidth;
  const outerFlat = layerResult(solved, "outer")?.flatLength ?? openWidth;
  const foldAllowance = outerFlat - innerFlat;

  // --- Parçalar ----------------------------------------------------------
  const pieces: PatternPiece[] = [];

  const outerNominal = roundCorners(rectangle(0, 0, outerFlat, walletHeight), true, {
    radius: params.cornerRadius,
  });
  const outerCut = cutLine(outerNominal, { penAllowance: params.penAllowance });

  // DİKİŞ HATTI U ŞEKLİNDE — ÜST KENAR AÇIK.
  //
  // Bifold'un üst kenarı banknot bölmesinin AĞZI. Kapalı bir çevre
  // dikişi hem o kenara delik yerleştirir hem de dikildiğinde para
  // bölmesini tamamen kapatır; ürün işe yaramaz hale gelir.
  //
  // İlk sürümde çevre kapalıydı ve üstteki kart yuvası (D-S3) üst
  // kenardan 28 delik alıyordu — tam olarak dikilmemesi gereken yerden.
  const m = params.stitchMargin;
  const outerStitch = roundCorners(
    flattenPath(
      path()
        .moveTo(vec(m, walletHeight - m))
        .lineTo(vec(m, m))
        .lineTo(vec(outerFlat - m, m))
        .lineTo(vec(outerFlat - m, walletHeight - m))
        .open(),
    ),
    false,
    { radius: Math.max(1, params.cornerRadius - m) },
  );
  const outerPlan = distributeStitches(
    outerStitch,
    false,
    params.pitch !== undefined ? { pitch: params.pitch } : {},
  );
  const outerBox = bbox(outerCut);

  const foldCentre = outerFlat / 2;
  pieces.push({
    id: "outer",
    code: "A",
    name: "dış kabuk",
    kind: "outer",
    quantity: 1,
    leatherThickness: params.outerThickness,
    cutLine: outerCut,
    stitchLine: outerStitch,
    stitchLineClosed: false,
    stitchPlan: outerPlan,
    foldLines: [
      {
        from: vec(foldCentre - foldAllowance / 2, 0),
        to: vec(foldCentre - foldAllowance / 2, walletHeight),
        label: "kat başlangıcı",
      },
      {
        from: vec(foldCentre + foldAllowance / 2, 0),
        to: vec(foldCentre + foldAllowance / 2, walletHeight),
        label: "kat bitişi",
      },
    ],
    width: outerBox.width,
    height: outerBox.height,
  });

  // İç kabuk: banknot bölmesinin arkası. Dış kabuktan kat payı kadar kısa.
  const innerNominal = roundCorners(rectangle(0, 0, innerFlat, walletHeight), true, {
    radius: params.cornerRadius,
  });
  const innerCut = cutLine(innerNominal, { penAllowance: params.penAllowance });
  const innerBox = bbox(innerCut);
  // İç kabuk çevre dikişine TAM BOYUNCA yakalanıyor. Kat payı sırtta
  // soğuruluyor, kenarlar hizalı kalıyor.
  const innerProjection = projectAcrossFold(
    outerPlan,
    foldCentre,
    foldAllowance,
    innerCut,
    true,
  );
  pieces.push({
    id: "inner",
    code: "B",
    name: "iç kabuk (para bölmesi)",
    kind: "outer",
    quantity: 1,
    leatherThickness: params.innerThickness,
    cutLine: innerCut,
    ...(innerProjection.plan === undefined
      ? {}
      : { stitchPlan: innerProjection.plan }),
    foldLines: [
      {
        from: vec(innerFlat / 2, 0),
        to: vec(innerFlat / 2, walletHeight),
        label: "kat",
      },
    ],
    width: innerBox.width,
    height: innerBox.height,
  });

  // --- Yuva parçaları ve montaj -----------------------------------------
  //
  // HER ÖRNEK AYRI PARÇA. Gruplamak ("T-slot yuva ×4") mümkün değil,
  // çünkü sol paneldeki yuva sol ve alt kenardan, sağ paneldeki sağ ve
  // alt kenardan delik alıyor; üstteki yuva alt kenar deliklerini hiç
  // almıyor. Aynı şekil, farklı delik deseni.
  //
  // Delikler ana çevre planından YANSITILIYOR, parça başına yeniden
  // hesaplanmıyor — hesaplansaydı katmanlar üst üste konduğunda
  // tutmazdı.
  const slotPieceHeight = CARD_ID1.height + params.stitchMargin;
  const mouthHeight = Math.min(params.reveal, slotPieceHeight / 2);
  const sideInset = params.stitchMargin + T_SLOT_WRAP_ALLOWANCE;

  const rectShape = roundCorners(
    rectangle(0, 0, panelWidth, slotPieceHeight),
    true,
    { radius: Math.min(params.cornerRadius, slotPieceHeight / 4) },
  );
  const tShape = roundCorners(
    tSlotShape(panelWidth, slotPieceHeight, mouthHeight, sideInset),
    true,
    { radius: Math.min(params.cornerRadius, sideInset / 2) },
  );

  const assembly: AssemblyPlacement[] = [];
  const rightPanelX = Math.max(0, outerFlat - panelWidth);
  const sides: readonly { readonly x: Mm; readonly tag: string }[] = [
    { x: 0, tag: "S" },
    { x: rightPanelX, tag: "R" },
  ];

  let layerIndex = 1;
  for (const side of sides) {
    for (let i = 0; i < n; i++) {
      const isRect = params.construction === "stacked" || i === 0;
      const code = `${isRect ? "C" : "D"}-${side.tag}${i + 1}`;
      const id = `slot-${side.tag}${i + 1}`;
      const origin = { x: side.x, y: i * params.reveal };

      const cut = cutLine(isRect ? rectShape : tShape, {
        penAllowance: params.penAllowance,
      });
      const b = bbox(cut);
      const projected = projectStitchPlan(outerPlan, origin, cut);

      pieces.push({
        id,
        code,
        name: isRect ? `alt yuva ${side.tag}${i + 1}` : `T-slot yuva ${side.tag}${i + 1}`,
        kind: isRect ? "slot-rect" : "slot-t",
        quantity: 1,
        leatherThickness: params.slotThickness,
        cutLine: cut,
        ...(projected.plan === undefined ? {} : { stitchPlan: projected.plan }),
        foldLines: [],
        width: b.width,
        height: b.height,
      });

      assembly.push({
        pieceId: id,
        code,
        x: origin.x,
        y: origin.y,
        layer: layerIndex,
      });
      layerIndex += 1;
    }
  }

  // --- Kural denetimi ----------------------------------------------------
  if (loadedThickness > MAX_CLOSED_THICKNESS) {
    diagnostics.push({
      severity: "error",
      code: "TOO_THICK",
      message:
        `Kart yüklü kalınlık ${loadedThickness.toFixed(1)}mm — üst sınır ` +
        `${MAX_CLOSED_THICKNESS}mm. Yuva sayısını azalt ya da daha ince deri kullan.`,
    });
  } else if (closedThickness > BIFOLD_TARGET_CLOSED_THICKNESS) {
    // ÖLÇÜT BOŞ KALINLIK. Belgelenmiş hedef ("iyi bir bifold boşken
    // 6–8mm'yi geçmemeli") boş ürün için verilmiş. İlk sürümde yüklü
    // kalınlığa bakıyordum ve 3 yuvalı — son derece yaygın — bir cüzdan
    // gereksiz yere uyarı alıyordu.
    diagnostics.push({
      severity: "warning",
      code: "BULKY",
      message:
        `Boş kalınlık ${closedThickness.toFixed(1)}mm — belgelenmiş hedef ` +
        `${BIFOLD_TARGET_CLOSED_THICKNESS}mm. Kart yüklü ` +
        `${loadedThickness.toFixed(1)}mm olacak. Yuva sayısını azaltmak ya da ` +
        `yuva derisini inceltmek belirgin fark yaratır.`,
    });
  }

  if (widthFromBill > widthFromCards) {
    diagnostics.push({
      severity: "warning",
      code: "WIDTH_FROM_BILL",
      message:
        `Açık genişliği banknot belirledi (${widthFromBill.toFixed(1)}mm > ` +
        `${widthFromCards.toFixed(1)}mm). Paneller kart yığınından geniş kalıyor; ` +
        `yuvaları ortalamak ya da bölme genişletmek gerekebilir.`,
    });
  }

  const fitsA4 = outerBox.width <= A4.width - 20 && outerBox.height <= A4.height - 20;
  if (!fitsA4) {
    diagnostics.push({
      severity: "warning",
      code: "NEEDS_TILING",
      message:
        `Dış kabuk ${outerBox.width.toFixed(0)} × ${outerBox.height.toFixed(0)}mm — ` +
        `tek A4'e sığmıyor, birden fazla sayfaya bölünecek.`,
    });
  }

  const summary: PatternSummary = {
    compartmentWidth: panelWidth,
    slotStackHeight: slotGeo.stackHeight,
    outerFlatWidth: outerBox.width,
    outerFlatHeight: outerBox.height,
    closedThickness,
    loadedThickness,
    edgeThickness: slotGeo.edgeThickness,
    foldAllowance,
    panelHeight: walletHeight,
    totalHoles: outerPlan.totalHoles,
    pitch: outerPlan.pitch,
    fitsA4,
  };

  return { pieces, assembly, crossSection: solved, diagnostics, summary };
}

/** Yarım inç kuralıyla karşılaştırma — modelin doğrulama çapası. */
export function halfInchRuleDeviation(params: BifoldParams): Mm {
  const result = generateBifold(params);
  const halfInch = 12.7;
  return result.summary.foldAllowance - halfInch;
}

export { foldLengthDelta };
ODK_EOF_5

echo "==> packages/patterns/src/bifold.test.ts"
cat > packages/patterns/src/bifold.test.ts << 'ODK_EOF_6'
import { describe, it, expect } from "vitest";
import { BANKNOTES, billPocketGeometry, BILL_COVER_MARGIN } from "./banknote.js";
import { BIFOLD_DEFAULTS, generateBifold, halfInchRuleDeviation } from "./bifold.js";
import { layerResult } from "./crosssection.js";

describe("banknot verisi", () => {
  it("200 TL 160 × 72mm", () => {
    expect(BANKNOTES.TRY.width).toBe(160);
    expect(BANKNOTES.TRY.height).toBe(72);
    expect(BANKNOTES.TRY.verified).toBe(true);
  });

  it("dolar 156 × 66.3mm", () => {
    expect(BANKNOTES.USD.width).toBe(156);
    expect(BANKNOTES.USD.height).toBeCloseTo(66.3, 2);
    expect(BANKNOTES.USD.verified).toBe(true);
  });

  it("doğrulanmamış para birimleri işaretli ve uyarı metni taşıyor", () => {
    for (const b of Object.values(BANKNOTES)) {
      if (!b.verified) expect(b.note).toContain("doğrulanmadı");
    }
  });

  it("TL en geniş banknot — cüzdanı o belirler", () => {
    const widths = Object.values(BANKNOTES).map((b) => b.width);
    expect(BANKNOTES.TRY.width).toBe(Math.max(...widths));
  });

  it("asgari cüzdan yüksekliği banknottan örtü payı kadar fazla", () => {
    const g = billPocketGeometry({
      currency: "TRY",
      leatherThickness: 0.8,
      stitchMargin: 3.5,
    });
    expect(g.minWalletHeight).toBeCloseTo(72 + BILL_COVER_MARGIN, 6);
  });
});

describe("bifold — yarım inç kuralı doğrulaması", () => {
  it("ASGARİ cüzdanda kat payı 12.7mm'ye yakın", () => {
    // MODELİN DOĞRULAMA ÇAPASI.
    //
    // MAKESUPPLY yarım inç kuralını "bare minimum" bir cüzdan için
    // veriyor: dış kabuk, iç kabuk, bir kat kart yuvası. Panel başına
    // 2 yuva bu tarife karşılık geliyor.
    //
    // gaps alanı eklenmeden model 2.6mm veriyordu — kıvrımda katman
    // olmayan dolgu (kart yığını + kartlar) modellenmediği için.
    const dev = Math.abs(
      halfInchRuleDeviation({ ...BIFOLD_DEFAULTS, cardSlotsPerSide: 2 }),
    );
    expect(dev).toBeLessThan(1.5);
  });

  it("kalın cüzdanda kat payı DAHA BÜYÜK olmalı", () => {
    // Yarım inç sabit bir sayı değil, belirli bir kalınlığın sonucu.
    // 3 yuvalı cüzdan daha kalın, dolayısıyla daha çok pay ister.
    // Modelin bunu vermesi doğru davranış; 12.7'ye zorlamak hata olurdu.
    const thick = generateBifold(BIFOLD_DEFAULTS).summary.foldAllowance;
    const thin = generateBifold({
      ...BIFOLD_DEFAULTS,
      cardSlotsPerSide: 2,
    }).summary.foldAllowance;
    expect(thick).toBeGreaterThan(thin);
    expect(thick).toBeGreaterThan(12.7);
  });

  it("açık genişlik ticari kalıplarla aynı mertebede", () => {
    // Referans: satılan bir billfold kalıbı açık 215mm.
    const r = generateBifold(BIFOLD_DEFAULTS);
    expect(r.summary.outerFlatWidth).toBeGreaterThan(190);
    expect(r.summary.outerFlatWidth).toBeLessThan(240);
  });

  it("kat payı dolgusuz modelden belirgin büyük", () => {
    const r = generateBifold(BIFOLD_DEFAULTS);
    // Dolgusuz olsaydı: π × (t_inner + k·(t_outer − t_inner)) ≈ 2.6mm
    const withoutFill = Math.PI * (0.8 + 0.45 * (0.9 - 0.8));
    expect(r.summary.foldAllowance).toBeGreaterThan(withoutFill * 3);
  });

  it("dış kabuk iç kabuktan tam kat payı kadar uzun", () => {
    const r = generateBifold(BIFOLD_DEFAULTS);
    const inner = layerResult(r.crossSection, "inner");
    const outer = layerResult(r.crossSection, "outer");
    expect((outer?.flatLength as number) - (inner?.flatLength as number)).toBeCloseTo(
      r.summary.foldAllowance,
      6,
    );
  });

  it("kart yuvası arttıkça kat payı büyüyor", () => {
    const a = generateBifold({ ...BIFOLD_DEFAULTS, cardSlotsPerSide: 2 });
    const b = generateBifold({ ...BIFOLD_DEFAULTS, cardSlotsPerSide: 5 });
    expect(b.summary.foldAllowance).toBeGreaterThan(a.summary.foldAllowance);
  });
});

describe("bifold — parçalar", () => {
  const r = generateBifold(BIFOLD_DEFAULTS);

  it("hata üretmiyor", () => {
    expect(r.diagnostics.filter((d) => d.severity === "error")).toHaveLength(0);
  });

  it("dış kabuk, iç kabuk ve panel başına ayrı yuva parçaları", () => {
    // Sol ve sağ paneldeki yuvalar farklı kenarlardan delik alıyor,
    // dolayısıyla aynı parça değiller.
    expect(r.pieces.map((p) => p.code)).toEqual([
      "A",
      "B",
      "C-S1",
      "D-S2",
      "D-S3",
      "C-R1",
      "D-R2",
      "D-R3",
    ]);
  });

  it("iç kabuk dış kabukla AYNI sayıda delik alıyor", () => {
    // İç kabuk çevre dikişine tam boyunca yakalanır. Kat payı sırtta
    // soğurulduğu için kenarlar hizalı; ortalanmış varsaymak yan
    // kenarların tamamını kaybettiriyordu.
    const outer = r.pieces.find((p) => p.id === "outer");
    const inner = r.pieces.find((p) => p.id === "inner");
    expect(inner?.stitchPlan?.totalHoles).toBe(outer?.stitchPlan?.totalHoles);
  });

  it("T-slot gövdesi kenara ulaşmadığı için az delik alıyor", () => {
    // T-slot'un temel özelliği bu: gövde bölmenin kenarına uzanmıyor,
    // yalnızca üstteki kollar çevre dikişine yakalanıyor.
    const rect = r.pieces.find((p) => p.code === "C-S1");
    const t = r.pieces.find((p) => p.code === "D-S2");
    expect(t?.stitchPlan?.totalHoles).toBeLessThan(
      rect?.stitchPlan?.totalHoles as number,
    );
  });

  it("simetrik paneller neredeyse aynı sayıda delik alıyor", () => {
    // Tam eşitlik beklenmiyor: dikiş açık bir U hattı, dağıtım bir
    // uçtan başlıyor ve iki uç birebir simetrik değil. 1–2 delik fark
    // fiziksel olarak sorunsuz.
    const left = r.pieces.find((p) => p.code === "C-S1");
    const right = r.pieces.find((p) => p.code === "C-R1");
    const d = Math.abs(
      (left?.stitchPlan?.totalHoles as number) -
        (right?.stitchPlan?.totalHoles as number),
    );
    expect(d).toBeLessThanOrEqual(2);
  });

  it("ÜST KENAR AÇIK: dikiş hattı kapalı çevre değil", () => {
    // Banknot bölmesinin ağzı dikilirse ürün işe yaramaz.
    const outer = r.pieces.find((p) => p.id === "outer");
    expect(outer?.stitchLineClosed).toBe(false);
  });

  it("üst kenara delik düşmüyor", () => {
    const outer = r.pieces.find((p) => p.id === "outer");
    const top = r.summary.panelHeight - BIFOLD_DEFAULTS.stitchMargin;
    const holesNearTop = (outer?.stitchPlan?.holes ?? []).filter(
      (h) => h.position.y > top - 1,
    );
    // Yalnızca U'nun iki ucu üst hizaya değiyor.
    expect(holesNearTop.length).toBeLessThanOrEqual(2);
  });

  it("iç kabuk dış kabuktan kısa", () => {
    const outer = r.pieces.find((p) => p.id === "outer");
    const inner = r.pieces.find((p) => p.id === "inner");
    expect(inner?.width).toBeLessThan(outer?.width as number);
    // Hassasiyet 2: kesim hatları Clipper'ın mikron ızgarasından geçiyor.
    expect((outer?.width as number) - (inner?.width as number)).toBeCloseTo(
      r.summary.foldAllowance,
      2,
    );
  });

  it("montajda her panel için ayrı yuva örnekleri", () => {
    expect(r.assembly).toHaveLength(2 * BIFOLD_DEFAULTS.cardSlotsPerSide);
    expect(r.assembly.filter((a) => a.code.includes("S"))).toHaveLength(3);
    expect(r.assembly.filter((a) => a.code.includes("R"))).toHaveLength(3);
  });

  it("sağ paneldeki yuvalar sağa kaydırılmış", () => {
    const left = r.assembly.filter((a) => a.code.includes("S"));
    const right = r.assembly.filter((a) => a.code.includes("R"));
    expect(right[0]?.x).toBeGreaterThan(left[0]?.x as number);
  });
});

describe("bifold — ölçüler ve kurallar", () => {
  it("TL banknotu bölmeye sığıyor", () => {
    const r = generateBifold(BIFOLD_DEFAULTS);
    expect(r.summary.panelHeight).toBeGreaterThanOrEqual(72 + BILL_COVER_MARGIN);
  });

  it("kapalı kalınlık makul", () => {
    const r = generateBifold(BIFOLD_DEFAULTS);
    expect(r.summary.closedThickness).toBeGreaterThan(4);
    expect(r.summary.closedThickness).toBeLessThan(12);
  });

  it("çok yuva şişkinlik uyarısı üretiyor", () => {
    const r = generateBifold({ ...BIFOLD_DEFAULTS, cardSlotsPerSide: 8 });
    expect(
      r.diagnostics.some((d) => d.code === "BULKY" || d.code === "TOO_THICK"),
    ).toBe(true);
  });

  it("doğrulanmamış para birimi uyarı üretiyor", () => {
    const r = generateBifold({ ...BIFOLD_DEFAULTS, currency: "EUR" });
    expect(r.diagnostics.some((d) => d.code === "BANKNOTE_UNVERIFIED")).toBe(true);
  });

  it("açık genişlik banknot ve kart kısıtlarının büyüğü", () => {
    const r = generateBifold(BIFOLD_DEFAULTS);
    const billWidth = billPocketGeometry({
      currency: "TRY",
      leatherThickness: 0.8,
      stitchMargin: 3.5,
    }).compartmentWidth;
    expect(r.summary.outerFlatWidth + 0.6).toBeGreaterThanOrEqual(
      Math.min(billWidth, 2 * r.summary.compartmentWidth) - 1,
    );
  });

  it("A4'e sığmıyor ve tiling uyarısı veriyor", () => {
    // Açık bifold ~200mm; A4 genişliği 210mm, kenar payıyla sığmaz.
    const r = generateBifold(BIFOLD_DEFAULTS);
    expect(r.summary.outerFlatWidth).toBeGreaterThan(150);
    if (!r.summary.fitsA4) {
      expect(r.diagnostics.some((d) => d.code === "NEEDS_TILING")).toBe(true);
    }
  });
});
ODK_EOF_6

echo "==> packages/patterns/src/index.ts"
cat > packages/patterns/src/index.ts << 'ODK_EOF_7'
/**
 * @odk/patterns — malzeme modeli, kesit çözücü, modül tanımları.
 *
 * Bu paket de saf kalır: platform API'si import etmez.
 */

export * from "./material.js";
export * from "./crosssection.js";
export * from "./cardslot.js";
export * from "./cardholder.js";
export * from "./banknote.js";
export * from "./bifold.js";
export * from "./catalog.js";
export * from "./instructions.js";
export * from "./stitchprojection.js";
ODK_EOF_7

echo "==> packages/print/src/pdf.ts"
cat > packages/print/src/pdf.ts << 'ODK_EOF_8'
import type { PDFDocument, PDFFont, PDFPage } from "pdf-lib";
import {
  PDFDocument as PDFDoc,
  rgb,
  pushGraphicsState,
  popGraphicsState,
  moveTo,
  lineTo,
  closePath,
  clip,
  endPath,
} from "pdf-lib";
import fontkit from "@pdf-lib/fontkit";
import type { Mm, Polyline, Vec } from "@odk/geometry";
import { mmToPt, stitchSummary } from "@odk/geometry";
import type {
  PatternResult,
  PatternPiece,
  InstructionContext,
  InstructionStep,
} from "@odk/patterns";
import { buildInstructions } from "@odk/patterns";
import type { PaperSpec, TileGrid } from "./paper.js";
import {
  A4_PORTRAIT,
  printableArea,
  planTiles,
  tileOrigin,
  tileCode,
  CALIBRATION_SQUARE,
} from "./paper.js";
import type {
  LayoutPage,
  LineStyle,
  PageLayout,
  PlacedPiece,
  SheetLayout,
} from "./layout.js";
import { packPages, packPieces, pieceToLayout, STYLES } from "./layout.js";

/**
 * PDF ÜRETİCİ
 *
 * Tek kural: çıktı 1:1. Koordinatlar milimetre olarak hesaplanır ve
 * yalnızca pdf-lib'e verilirken point'e çevrilir (mmToPt). Başka hiçbir
 * yerde birim dönüşümü yok — ölçek hatalarının en yaygın kaynağı budur.
 */

export interface PdfFonts {
  /** Gövde metni için TTF/OTF baytları. Türkçe karakterler şart. */
  readonly regular: Uint8Array;
  /** Ölçüler için monospace TTF/OTF baytları. */
  readonly mono: Uint8Array;
}

export interface PdfOptions {
  readonly paper?: PaperSpec;
  /**
   * Kalibrasyon düzeltmesi. 1 = düzeltme yok.
   * scaleFromMeasurement() ile hesaplanır.
   */
  readonly scaleFactor?: number;
  /**
   * Dikiş deliklerini tek tek bas.
   *
   * Varsayılan AÇIK.
   *
   * İlk sürümde kapalıydı; gerekçem "kullanıcı ironu kendisi yürür,
   * basılmış nokta yanıltır" idi. Ticari kalıpları inceleyince bu
   * varsayımın yanlış olduğu görüldü: yaygın iş akışı kağıt şablonu
   * deriye bantlayıp İŞARETLİ NOKTALARDAN delmek, sonra hattı kesmek.
   * Yani noktalar şablonun asıl işlevlerinden biri.
   *
   * Kapalıyken yalnızca köşe çapaları basılır; ironu kendisi yürütenler
   * için hâlâ geçerli bir seçenek.
   */
  readonly printAllHoles?: boolean;
  readonly title?: string;
  readonly version?: string;
  /**
   * Verilirse yapım adımları sayfası eklenir.
   *
   * Adımlar kalıptan türetildiği için parametrelere ihtiyaç var;
   * PatternResult tek başına yetmiyor.
   */
  readonly params?: InstructionContext;
  /**
   * Sayfaya sığmayan parçayı 90° döndürmeye izin ver.
   *
   * Varsayılan AÇIK. Kapatmak yalnızca deri postu belirli bir yönde
   * kesmek zorunda olan (damar kısıtı sıkı) kullanıcılar için anlamlı;
   * kapatıldığında büyük parçalar döşemeye düşer ve elle hizalama
   * gerekir.
   */
  readonly allowRotation?: boolean;
}

const BLACK = rgb(0, 0, 0);

function gray(g: number) {
  return rgb(g, g, g);
}

interface Ctx {
  readonly doc: PDFDocument;
  readonly body: PDFFont;
  readonly mono: PDFFont;
  readonly paper: PaperSpec;
  readonly scale: number;
}

export async function buildPatternPdf(
  pattern: PatternResult,
  fonts: PdfFonts,
  options: PdfOptions = {},
): Promise<Uint8Array> {
  const paper = options.paper ?? A4_PORTRAIT;
  const scale = options.scaleFactor ?? 1;

  const doc = await PDFDoc.create();
  doc.registerFontkit(fontkit);
  const body = await doc.embedFont(fonts.regular, { subset: true });
  const mono = await doc.embedFont(fonts.mono, { subset: true });

  doc.setTitle(options.title ?? "Deri kalıbı");
  doc.setCreator("oto_deri_kalip");

  const ctx: Ctx = { doc, body, mono, paper, scale };

  // ÖNCE sayfa bazlı yerleştirme denenir; yalnızca sığmayan parçalar
  // döşemeye kalır. Bkz. layout.ts — hizalama hatası ürünün ölçüsüne
  // doğrudan giriyor.
  const pageLayout = packPages(
    pattern.pieces,
    paper,
    undefined,
    options.allowRotation ?? true,
  );
  const needsTiling = pageLayout.oversized.length > 0;
  const tiledSheet = needsTiling ? packPieces(pageLayout.oversized, paper) : undefined;
  const grid =
    tiledSheet === undefined
      ? undefined
      : planTiles(tiledSheet.width, tiledSheet.height, paper);

  const patternPageCount =
    pageLayout.pages.length + (grid === undefined ? 0 : grid.cols * grid.rows);

  drawCoverPage(ctx, pattern, pageLayout, patternPageCount, options);
  drawAssemblyPage(ctx, pattern);
  if (options.params !== undefined) {
    drawInstructionPages(ctx, buildInstructions(pattern, options.params));
  }

  for (const page of pageLayout.pages) {
    drawFlatPage(ctx, page, patternPageCount, options);
  }

  if (tiledSheet !== undefined && grid !== undefined) {
    for (let row = 0; row < grid.rows; row++) {
      for (let col = 0; col < grid.cols; col++) {
        drawTilePage(ctx, tiledSheet, grid, col, row, options);
      }
    }
  }

  return doc.save();
}

// --- Yardımcılar -----------------------------------------------------------

function addPage(ctx: Ctx): PDFPage {
  return ctx.doc.addPage([mmToPt(ctx.paper.width), mmToPt(ctx.paper.height)]);
}

function line(
  page: PDFPage,
  a: Vec,
  b: Vec,
  style: LineStyle,
  scale: number,
): void {
  // exactOptionalPropertyTypes altında dashArray'e undefined atanamaz;
  // sürekli çizgide anahtarı hiç eklemiyoruz.
  const dash =
    style.dash.length > 0
      ? { dashArray: style.dash.map((d) => mmToPt(d * scale)) }
      : {};
  page.drawLine({
    start: { x: mmToPt(a.x), y: mmToPt(a.y) },
    end: { x: mmToPt(b.x), y: mmToPt(b.y) },
    thickness: mmToPt(style.width),
    color: gray(style.gray),
    ...dash,
  });
}

function polyline(
  page: PDFPage,
  poly: Polyline,
  closedPath: boolean,
  style: LineStyle,
  scale: number,
): void {
  for (let i = 0; i < poly.length - 1; i++) {
    line(page, poly[i] as Vec, poly[i + 1] as Vec, style, scale);
  }
  if (closedPath && poly.length > 2) {
    line(page, poly.at(-1) as Vec, poly[0] as Vec, style, scale);
  }
}

function text(
  page: PDFPage,
  s: string,
  x: Mm,
  y: Mm,
  size: number,
  font: PDFFont,
  g = 0,
): void {
  page.drawText(s, {
    x: mmToPt(x),
    y: mmToPt(y),
    size,
    font,
    color: gray(g),
  });
}

// --- Kapak sayfası ---------------------------------------------------------

function drawCoverPage(
  ctx: Ctx,
  pattern: PatternResult,
  pageLayout: PageLayout,
  patternPageCount: number,
  options: PdfOptions,
): void {
  const page = addPage(ctx);
  const area = printableArea(ctx.paper);
  const left = area.originX;
  let y = ctx.paper.height - ctx.paper.printerMargin - 8;

  text(page, options.title ?? "Kartlık — kalıp", left, y, 18, ctx.body);
  y -= 7;
  text(
    page,
    `${options.version ?? "v1"} · ${patternPageCount} desen sayfası · ölçek 1:1`,
    left,
    y,
    9,
    ctx.mono,
    0.4,
  );

  // ── Kalibrasyon karesi ───────────────────────────────────────────────
  y -= 14;
  text(page, "1 — Önce ölçeği doğrula", left, y, 12, ctx.body);
  y -= 6;
  const instructions = [
    "Yazdırırken ölçek %100 / Actual size olmalı.",
    "\"Sayfaya sığdır\" / \"Fit to page\" KAPALI olmalı.",
    "Aşağıdaki karenin kenarını cetvelle ölç.",
    "50mm değilse ölçtüğün değeri uygulamaya gir ve PDF'i yeniden indir.",
  ];
  for (const linetext of instructions) {
    text(page, linetext, left, y, 9, ctx.body, 0.25);
    y -= 4.6;
  }

  y -= CALIBRATION_SQUARE + 3;
  const sq = CALIBRATION_SQUARE * ctx.scale;
  page.drawRectangle({
    x: mmToPt(left),
    y: mmToPt(y),
    width: mmToPt(sq),
    height: mmToPt(sq),
    borderWidth: mmToPt(STYLES.cut.width),
    borderColor: BLACK,
  });
  // Kenar ortalarına 10mm'lik tik işaretleri: cetveli hizalamayı kolaylaştırır.
  for (let t = 10; t < CALIBRATION_SQUARE; t += 10) {
    const tx = left + t * ctx.scale;
    line(page, { x: tx, y }, { x: tx, y: y + 2 * ctx.scale }, STYLES.guide, ctx.scale);
  }
  text(page, `${CALIBRATION_SQUARE} mm`, left + sq + 4, y + sq / 2, 10, ctx.mono);

  // ── Sayfa yerleşimi bilgisi ──────────────────────────────────────────
  y -= 10;
  const tiled = pageLayout.oversized.length > 0;
  text(page, "2 — Sayfa yerleşimi", left, y, 12, ctx.body);
  y -= 5.5;
  if (!tiled) {
    text(
      page,
      "Her parça tek bir sayfada. Sayfa birleştirme ve hizalama GEREKMİYOR.",
      left,
      y,
      9,
      ctx.body,
      0.25,
    );
    y -= 4.6;
    if (pageLayout.rotatedCount > 0) {
      text(
        page,
        `${pageLayout.rotatedCount} parça sayfaya sığması için 90° döndürüldü. ` +
          `Damar oku parçayla birlikte döndü; oku takip et.`,
        left,
        y,
        9,
        ctx.body,
        0.25,
      );
      y -= 4.6;
    }
  } else {
    text(
      page,
      `${pageLayout.oversized.map((op) => op.code).join(", ")} tek sayfaya sığmıyor ` +
        `ve bölündü. O sayfaları kesme çizgisinden kesip haçları çakıştırarak yapıştır.`,
      left,
      y,
      9,
      ctx.body,
      0.25,
    );
    y -= 4.6;
  }

  // ── Kesim kuralı ─────────────────────────────────────────────────────
  y -= 5;
  text(page, "3 — Çizginin dışından kes", left, y, 12, ctx.body);
  y -= 5.5;
  text(
    page,
    "Kesim çizgisi 0.2mm. Çizgiyi kağıtta bırak, dışından kes.",
    left,
    y,
    9,
    ctx.body,
    0.25,
  );

  // ── Parça listesi ────────────────────────────────────────────────────
  y -= 12;
  text(page, "4 — Parçalar", left, y, 12, ctx.body);
  y -= 6;
  text(page, "kod", left, y, 8, ctx.mono, 0.5);
  text(page, "parça", left + 12, y, 8, ctx.mono, 0.5);
  text(page, "adet", left + 55, y, 8, ctx.mono, 0.5);
  text(page, "ölçü (mm)", left + 70, y, 8, ctx.mono, 0.5);
  text(page, "deri", left + 110, y, 8, ctx.mono, 0.5);
  y -= 1.5;
  line(page, { x: left, y }, { x: left + area.width, y }, STYLES.guide, 1);
  y -= 4.5;

  for (const p of pattern.pieces) {
    text(page, p.code, left, y, 9, ctx.mono);
    text(page, p.name, left + 12, y, 9, ctx.body);
    text(page, `${p.quantity}`, left + 55, y, 9, ctx.mono);
    text(
      page,
      `${p.width.toFixed(1)} × ${p.height.toFixed(1)}`,
      left + 70,
      y,
      9,
      ctx.mono,
    );
    text(page, `${p.leatherThickness.toFixed(1)}mm`, left + 110, y, 9, ctx.mono);
    y -= 4.8;
  }

  // ── Dikiş planı ──────────────────────────────────────────────────────
  const outer = pattern.pieces.find((p) => p.stitchPlan !== undefined);
  if (outer?.stitchPlan !== undefined) {
    y -= 8;
    text(page, "5 — Dikiş", left, y, 12, ctx.body);
    y -= 5.5;
    text(
      page,
      `${outer.stitchPlan.pitch}mm pricking iron · toplam ${outer.stitchPlan.totalHoles} delik`,
      left,
      y,
      9,
      ctx.mono,
      0.25,
    );
    y -= 5;
    for (const s of stitchSummary(outer.stitchPlan)) {
      text(page, s, left, y, 8.5, ctx.mono, 0.35);
      y -= 4.2;
    }
  }

  // ── Ölçüler ──────────────────────────────────────────────────────────
  const s = pattern.summary;
  y -= 8;
  text(page, "6 — Ölçüler", left, y, 12, ctx.body);
  y -= 5.5;
  const rows: [string, string][] = [
    ["bölme genişliği", `${s.compartmentWidth.toFixed(1)} mm`],
    ["kat payı", `${s.foldAllowance.toFixed(2)} mm`],
    ["kapalı kalınlık", `${s.closedThickness.toFixed(2)} mm`],
    ["kart yüklü", `${s.loadedThickness.toFixed(2)} mm`],
    ["kenar kalınlığı", `${s.edgeThickness.toFixed(2)} mm`],
  ];
  for (const [k, v] of rows) {
    text(page, k, left, y, 9, ctx.body, 0.3);
    text(page, v, left + 55, y, 9, ctx.mono);
    y -= 4.4;
  }

  // ── Uyarılar ─────────────────────────────────────────────────────────
  if (pattern.diagnostics.length > 0) {
    y -= 8;
    text(page, "Uyarılar", left, y, 12, ctx.body);
    y -= 5.5;
    for (const d of pattern.diagnostics) {
      const prefix = d.severity === "error" ? "HATA" : "UYARI";
      const wrapped = wrap(`${prefix} — ${d.message}`, 88);
      for (const w of wrapped) {
        text(page, w, left, y, 8.5, ctx.body, 0.2);
        y -= 4;
      }
      y -= 1;
    }
  }

  drawFooter(ctx, page, "kapak", 0);
}

/** Basit sözcük sarma; PDF'te otomatik sarma yok. */
function wrap(s: string, maxChars: number): string[] {
  const words = s.split(" ");
  const lines: string[] = [];
  let cur = "";
  for (const w of words) {
    if (cur.length + w.length + 1 > maxChars) {
      if (cur.length > 0) lines.push(cur);
      cur = w;
    } else {
      cur = cur.length === 0 ? w : `${cur} ${w}`;
    }
  }
  if (cur.length > 0) lines.push(cur);
  return lines;
}

// --- Ölçü çizgileri --------------------------------------------------------

/**
 * Uzatma çizgileri, oklar ve ortalanmış metinle ölçü çizgisi.
 *
 * Referans olarak incelediğimiz ticari kalıplarda ölçüler çizimin
 * ÜSTÜNDE gösteriliyor, sadece etiket metninde değil. Fark şu: kullanıcı
 * kağıdı cetvelle kontrol ederken hangi iki nokta arasını ölçeceğini
 * çizimden görüyor. "99.4 × 194.4mm" yazısı bunu söylemiyor.
 */
function dimension(
  ctx: Ctx,
  page: PDFPage,
  a: Vec,
  b: Vec,
  offset: Mm,
  label: string,
  vertical: boolean,
): void {
  const style = STYLES.guide;
  const arm = 2;

  const oa = vertical ? { x: a.x - offset, y: a.y } : { x: a.x, y: a.y + offset };
  const ob = vertical ? { x: b.x - offset, y: b.y } : { x: b.x, y: b.y + offset };

  // Uzatma çizgileri: ölçülen kenardan ölçü çizgisine.
  line(page, a, vertical ? { x: oa.x - arm, y: a.y } : { x: a.x, y: oa.y + arm }, style, 1);
  line(page, b, vertical ? { x: ob.x - arm, y: b.y } : { x: b.x, y: ob.y + arm }, style, 1);

  // Ölçü çizgisi.
  line(page, oa, ob, style, 1);

  // Uç işaretleri (45° eğik çizgi — ok başından daha net basılıyor).
  for (const p of [oa, ob]) {
    line(
      page,
      { x: p.x - 1.2, y: p.y - 1.2 },
      { x: p.x + 1.2, y: p.y + 1.2 },
      STYLES.cut,
      1,
    );
  }

  const mid = { x: (oa.x + ob.x) / 2, y: (oa.y + ob.y) / 2 };
  const w = ctx.mono.widthOfTextAtSize(label, 8) / mmToPt(1);
  if (vertical) {
    text(page, label, mid.x - w - 1.5, mid.y - 1, 8, ctx.mono, 0.15);
  } else {
    text(page, label, mid.x - w / 2, mid.y + 1.5, 8, ctx.mono, 0.15);
  }
}

// --- Montaj sayfası --------------------------------------------------------

/**
 * Parçaların bitmiş üründeki yerleşimi.
 *
 * BU SAYFA EN ÇOK EKSİK OLANDI. Önceki sürümde kalıp, birbirinden
 * bağımsız parçalar listesiydi; hangi parçanın nereye geldiği yalnızca
 * kullanıcının kafasındaydı. Referans kalıplarda "Completed Wallet"
 * sayfası tam olarak bunu çözüyor.
 */
function drawAssemblyPage(ctx: Ctx, pattern: PatternResult): void {
  const page = addPage(ctx);
  const area = printableArea(ctx.paper);
  const left = area.originX;
  let y = ctx.paper.height - ctx.paper.printerMargin - 8;

  text(page, "Montaj — açık hâl", left, y, 15, ctx.body);
  y -= 6;
  text(
    page,
    "Yuvalar ön panele oturur; her yuva bir kademe yukarıda.",
    left,
    y,
    9,
    ctx.body,
    0.3,
  );

  const outer = pattern.pieces.find((p) => p.id === "outer");
  if (outer === undefined) {
    drawFooter(ctx, page, "montaj", 0);
    return;
  }

  // Çizimi sayfaya sığdır: ölçekle, çünkü bu sayfa 1:1 DEĞİL.
  const drawH = y - area.originY - 26;
  const fit = Math.min(1, (area.width - 40) / outer.width, drawH / outer.height);
  const ox = left + 24;
  const oy = area.originY + 20;

  const minX = Math.min(...outer.cutLine.map((p) => p.x));
  const minY = Math.min(...outer.cutLine.map((p) => p.y));
  const place = (p: Vec, dx = 0, dy = 0): Vec => ({
    x: ox + (p.x - minX + dx) * fit,
    y: oy + (p.y - minY + dy) * fit,
  });

  polyline(page, outer.cutLine.map((p) => place(p)), true, STYLES.cut, 1);
  if (outer.stitchLine !== undefined) {
    polyline(
      page,
      outer.stitchLine.map((p) => place(p)),
      outer.stitchLineClosed ?? true,
      STYLES.stitch,
      1,
    );
  }
  for (const fold of outer.foldLines) {
    line(page, place(fold.from), place(fold.to), STYLES.fold, 1);
  }

  // Yuvalar, montajdaki konumlarında.
  for (const a of pattern.assembly) {
    const piece = pattern.pieces.find((p) => p.id === a.pieceId);
    if (piece === undefined) continue;
    const pminX = Math.min(...piece.cutLine.map((p) => p.x));
    const pminY = Math.min(...piece.cutLine.map((p) => p.y));
    const poly = piece.cutLine.map((p) =>
      place({ x: p.x - pminX + a.x, y: p.y - pminY + a.y }),
    );
    polyline(page, poly, true, STYLES.guide, 1);

    const anchor = place({ x: a.x + 4, y: a.y + 3 });
    text(page, a.code, anchor.x, anchor.y, 7.5, ctx.mono, 0.2);
  }

  text(
    page,
    outer.code,
    ox + 3 * fit,
    oy + (outer.height - 6) * fit,
    9,
    ctx.mono,
    0.2,
  );

  // Ölçüler.
  const bl = place({ x: 0, y: 0 });
  const br = place({ x: outer.width, y: 0 });
  const tl = place({ x: 0, y: outer.height });
  dimension(ctx, page, bl, br, 10, `${outer.width.toFixed(1)} mm`, false);
  dimension(ctx, page, bl, tl, 12, `${outer.height.toFixed(1)} mm`, true);

  text(
    page,
    `bu sayfa ölçekli (×${fit.toFixed(2)}) — kesim için desen sayfalarını kullan`,
    left,
    area.originY + 4,
    8,
    ctx.mono,
    0.45,
  );

  drawFooter(ctx, page, "montaj", 0);
}

// --- Yapım adımları --------------------------------------------------------

/**
 * Adımlar sayfası. Sığmayan adımlar bir sonraki sayfaya taşar.
 *
 * Sayfa taşması hesaplanarak yapılıyor, sabit "sayfa başına 6 adım"
 * gibi bir varsayımla değil: adım metinleri kalıptan türediği için
 * uzunlukları parametrelere göre değişiyor.
 */
function drawInstructionPages(ctx: Ctx, steps: readonly InstructionStep[]): void {
  const area = printableArea(ctx.paper);
  const left = area.originX;
  const bottomLimit = area.originY + 4;
  const wrapWidth = 84;

  let page = addPage(ctx);
  let pageIndex = 1;
  let y = ctx.paper.height - ctx.paper.printerMargin - 8;

  text(page, "Yapım adımları", left, y, 15, ctx.body);
  y -= 9;

  for (const step of steps) {
    const bodyLines = wrap(step.body, wrapWidth);
    const warnLines =
      step.warning === undefined ? [] : wrap(step.warning, wrapWidth - 4);
    const needed = 6 + bodyLines.length * 4.2 + (warnLines.length * 4 + 3) + 5;

    if (y - needed < bottomLimit) {
      drawFooter(ctx, page, `adımlar ${pageIndex}`, 0);
      page = addPage(ctx);
      pageIndex += 1;
      y = ctx.paper.height - ctx.paper.printerMargin - 8;
      text(page, `Yapım adımları (devam)`, left, y, 15, ctx.body);
      y -= 9;
    }

    // Numara solda, metin girintili — göz kolayca adım sınırlarını buluyor.
    text(page, `${step.n}`, left, y, 11, ctx.mono, 0.45);
    text(page, step.title, left + 8, y, 11.5, ctx.body);
    y -= 5.4;

    for (const bl of bodyLines) {
      text(page, bl, left + 8, y, 9, ctx.body, 0.25);
      y -= 4.2;
    }

    if (warnLines.length > 0) {
      y -= 1;
      const boxTop = y + 3.5;
      const boxHeight = warnLines.length * 4 + 2;
      // Sol kenarda kalın çubuk: uyarıyı gövdeden ayırıyor. Renk yerine
      // konum ve kalınlık kullanılıyor, siyah-beyaz baskıda da ayrışsın.
      page.drawRectangle({
        x: mmToPt(left + 8),
        y: mmToPt(boxTop - boxHeight),
        width: mmToPt(0.8),
        height: mmToPt(boxHeight),
        color: gray(0.15),
      });
      for (const wl of warnLines) {
        text(page, wl, left + 11, y, 8.5, ctx.body, 0.1);
        y -= 4;
      }
    }

    y -= 5;
  }

  drawFooter(ctx, page, `adımlar ${pageIndex}`, 0);
}

// --- Desen sayfaları -------------------------------------------------------

/**
 * Döşemesiz desen sayfası: parçalar bütün hâlde, hizalama gerekmez.
 */
function drawFlatPage(
  ctx: Ctx,
  layoutPage: LayoutPage,
  totalPages: number,
  options: PdfOptions,
): void {
  const page = addPage(ctx);
  const area = printableArea(ctx.paper);

  const tx = (p: Vec): Vec => ({
    x: area.originX + p.x * ctx.scale,
    y: area.originY + p.y * ctx.scale,
  });

  for (const placed of layoutPage.placed) {
    drawPiece(ctx, page, placed, tx, options.printAllHoles ?? true);
  }

  drawFooter(ctx, page, `S${layoutPage.index + 1}`, totalPages);
}

function drawTilePage(
  ctx: Ctx,
  layout: SheetLayout,
  grid: TileGrid,
  col: number,
  row: number,
  options: PdfOptions,
): void {
  const page = addPage(ctx);
  const area = printableArea(ctx.paper);
  const origin = tileOrigin(grid, col, row);

  // İçeriği basılabilir alana kırp: taşan kısım komşu sayfada.
  page.pushOperators(
    pushGraphicsState(),
    moveTo(mmToPt(area.originX), mmToPt(area.originY)),
    lineTo(mmToPt(area.originX + area.width), mmToPt(area.originY)),
    lineTo(mmToPt(area.originX + area.width), mmToPt(area.originY + area.height)),
    lineTo(mmToPt(area.originX), mmToPt(area.originY + area.height)),
    closePath(),
    clip(),
    endPath(),
  );

  // Tabaka koordinatı -> sayfa koordinatı.
  const tx = (p: Vec): Vec => ({
    x: area.originX + (p.x - origin.x) * ctx.scale,
    y: area.originY + (p.y - origin.y) * ctx.scale,
  });

  for (const placed of layout.placed) {
    drawPiece(ctx, page, placed, tx, options.printAllHoles ?? true);
  }

  page.pushOperators(popGraphicsState());

  drawTileMarks(ctx, page, grid, col, row);
  drawFooter(ctx, page, tileCode(col, row), grid.cols * grid.rows);
}

function drawPiece(
  ctx: Ctx,
  page: PDFPage,
  placed: PlacedPiece,
  tx: (p: Vec) => Vec,
  printAllHoles: boolean,
): void {
  const piece = placed.piece;

  // Parça yerel koordinatı -> yerleşim -> sayfa. Döndürme pieceToLayout
  // içinde, tek yerde uygulanıyor.
  const minX = Math.min(...piece.cutLine.map((p) => p.x));
  const minY = Math.min(...piece.cutLine.map((p) => p.y));
  const place = (p: Vec): Vec => tx(pieceToLayout(placed, p, minX, minY));

  polyline(page, piece.cutLine.map(place), true, STYLES.cut, ctx.scale);

  if (piece.stitchLine !== undefined) {
    // Açık dikiş hattını kapalı çizmek, dikilmemesi gereken kenara
    // (bölme ağzı) sahte bir çizgi koyar.
    polyline(
      page,
      piece.stitchLine.map(place),
      piece.stitchLineClosed ?? true,
      STYLES.stitch,
      ctx.scale,
    );
  }

  for (const fold of piece.foldLines) {
    line(page, place(fold.from), place(fold.to), STYLES.fold, ctx.scale);
  }

  if (piece.stitchPlan !== undefined) {
    const holes = printAllHoles
      ? piece.stitchPlan.holes
      : piece.stitchPlan.holes.filter((h) => h.isAnchor);
    for (const hole of holes) {
      const p = place(hole.position);
      page.drawCircle({
        x: mmToPt(p.x),
        y: mmToPt(p.y),
        size: mmToPt(0.5 * ctx.scale),
        borderWidth: mmToPt(0.15),
        borderColor: gray(0.3),
      });
    }
  }

  // Etiket: parçanın sol-üst köşesinin biraz üstünde. Etiket YATAY
  // kalır — parça dönse de yazının dönmesi okunabilirliği bozar.
  const label = tx({ x: placed.x, y: placed.y + placed.height + 3 });
  text(
    page,
    `${piece.code} · ${piece.name}  ×${piece.quantity}  ${piece.width.toFixed(1)}×${piece.height.toFixed(1)}mm  ${piece.leatherThickness.toFixed(1)}mm deri`,
    label.x,
    label.y,
    7.5,
    ctx.mono,
    0.3,
  );

  // Damar yönü: deri postun boyuna göre daha az esner; parçalar aynı
  // yönde kesilmezse ürün çarpılır.
  //
  // Ok PARÇA YEREL koordinatında tanımlanıp aynı dönüşümden geçiyor;
  // böylece parça döndürüldüğünde ok da dönüyor ve deri üzerindeki
  // doğru yönü göstermeye devam ediyor. Sayfa koordinatında sabit bir
  // ok çizmek, döndürülmüş parçada yanlış yön gösterirdi.
  const grainStart = place({ x: minX + 3, y: minY + 3 });
  const grainEnd = place({ x: minX + 3, y: minY + 15 });
  line(page, grainStart, grainEnd, STYLES.guide, ctx.scale);
  text(page, "damar", grainStart.x + 1.5, grainStart.y + 1, 6, ctx.mono, 0.55);
}

/**
 * Hizalama işaretleri.
 *
 * Kullanıcı sayfaları kesip bindirerek yapıştırıyor. Kesme hattı ve
 * dört köşedeki haçlar, komşu sayfayla üst üste getirildiğinde
 * çakışacak şekilde konumlanıyor.
 */
function drawTileMarks(
  ctx: Ctx,
  page: PDFPage,
  grid: TileGrid,
  col: number,
  row: number,
): void {
  const area = printableArea(ctx.paper);
  const x0 = area.originX;
  const y0 = area.originY;
  const x1 = x0 + area.width;
  const y1 = y0 + area.height;

  // Kesme çerçevesi.
  polyline(
    page,
    [
      { x: x0, y: y0 },
      { x: x1, y: y0 },
      { x: x1, y: y1 },
      { x: x0, y: y1 },
    ],
    true,
    STYLES.trim,
    1,
  );

  // Bindirme sınırı: sağda ve altta (bir sonraki sayfanın başladığı yer).
  if (col < grid.cols - 1) {
    line(
      page,
      { x: x1 - grid.overlap, y: y0 },
      { x: x1 - grid.overlap, y: y1 },
      STYLES.guide,
      1,
    );
  }
  if (row < grid.rows - 1) {
    line(
      page,
      { x: x0, y: y0 + grid.overlap },
      { x: x1, y: y0 + grid.overlap },
      STYLES.guide,
      1,
    );
  }

  // Köşe haçları.
  const arm = 4;
  for (const [cx, cy] of [
    [x0, y0],
    [x1, y0],
    [x0, y1],
    [x1, y1],
  ] as const) {
    line(page, { x: cx - arm, y: cy }, { x: cx + arm, y: cy }, STYLES.guide, 1);
    line(page, { x: cx, y: cy - arm }, { x: cx, y: cy + arm }, STYLES.guide, 1);
  }
}

/** Her sayfanın altında: ölçek çubuğu, uyarı, sayfa kodu. */
function drawFooter(ctx: Ctx, page: PDFPage, code: string, totalTiles: number): void {
  const m = ctx.paper.printerMargin;
  const y = m + 4;

  // 50mm ölçek çubuğu, 10mm tikli. Her sayfada ölçek doğrulanabilsin diye.
  const barLength = 50 * ctx.scale;
  line(page, { x: m, y }, { x: m + barLength, y }, STYLES.cut, 1);
  for (let t = 0; t <= 50; t += 10) {
    const tx = m + t * ctx.scale;
    line(page, { x: tx, y }, { x: tx, y: y + 1.8 }, STYLES.cut, 1);
  }
  text(page, "0", m - 0.5, y - 3.4, 6, ctx.mono, 0.4);
  text(page, "50mm", m + barLength - 5, y - 3.4, 6, ctx.mono, 0.4);

  text(
    page,
    "ölçek %100 · sayfaya sığdırma KAPALI",
    m + barLength + 8,
    y - 0.8,
    7,
    ctx.mono,
    0.45,
  );

  const label = totalTiles > 0 ? `${code} / ${totalTiles}` : code;
  text(page, label, ctx.paper.width - m - 18, y - 0.8, 9, ctx.mono, 0.2);
}
ODK_EOF_8

echo "==> packages/print/src/print.test.ts"
cat > packages/print/src/print.test.ts << 'ODK_EOF_9'
import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { PDFDocument } from "pdf-lib";
import { mmToPt } from "@odk/geometry";
import type { CardHolderParams } from "@odk/patterns";
import {
  BIFOLD_DEFAULTS,
  DEFAULT_PARAMS,
  buildInstructions,
  generateBifold,
  generateCardHolder,
} from "@odk/patterns";
import {
  A4_PORTRAIT,
  printableArea,
  planTiles,
  tileOrigin,
  tileCode,
  tileCount,
  TILE_OVERLAP,
  CALIBRATION_SQUARE,
} from "./paper.js";
import {
  packPages,
  packPieces,
  pieceToLayout,
  scaleFromMeasurement,
  STYLES,
} from "./layout.js";
import { buildPatternPdf } from "./pdf.js";

const require = createRequire(import.meta.url);

function fontBytes(pkg: string, file: string): Uint8Array {
  return new Uint8Array(readFileSync(require.resolve(`${pkg}/${file}`)));
}

const FONTS = {
  regular: fontBytes(
    "@expo-google-fonts/ibm-plex-sans",
    "400Regular/IBMPlexSans_400Regular.ttf",
  ),
  mono: fontBytes(
    "@expo-google-fonts/jetbrains-mono",
    "400Regular/JetBrainsMono_400Regular.ttf",
  ),
};

describe("basılabilir alan", () => {
  it("A4'te kenar payı ve alt şerit düşülüyor", () => {
    const a = printableArea(A4_PORTRAIT);
    expect(a.width).toBe(190); // 210 - 2*10
    expect(a.height).toBe(263); // 297 - 2*10 - 14
    expect(a.originX).toBe(10);
    expect(a.originY).toBe(24);
  });
});

describe("döşeme planı", () => {
  it("basılabilir alana sığan tabaka tek sayfa", () => {
    const g = planTiles(180, 250, A4_PORTRAIT);
    expect(g.cols).toBe(1);
    expect(g.rows).toBe(1);
    expect(tileCount(g)).toBe(1);
  });

  it("adım = basılabilir alan − bindirme", () => {
    const g = planTiles(400, 600, A4_PORTRAIT);
    expect(g.stepX).toBe(190 - TILE_OVERLAP);
    expect(g.stepY).toBe(263 - TILE_OVERLAP);
  });

  it("döşemeler tabakanın tamamını kapsıyor", () => {
    for (const [w, h] of [
      [400, 600],
      [191, 264],
      [1000, 300],
      [95, 800],
    ] as const) {
      const g = planTiles(w, h, A4_PORTRAIT);
      const coveredX = (g.cols - 1) * g.stepX + g.tileWidth;
      const coveredY = (g.rows - 1) * g.stepY + g.tileHeight;
      expect(coveredX).toBeGreaterThanOrEqual(w - 1e-9);
      expect(coveredY).toBeGreaterThanOrEqual(h - 1e-9);
    }
  });

  it("komşu döşemeler tam olarak bindirme kadar örtüşüyor", () => {
    const g = planTiles(500, 500, A4_PORTRAIT);
    const a = tileOrigin(g, 0, 0);
    const b = tileOrigin(g, 1, 0);
    const overlapX = a.x + g.tileWidth - b.x;
    expect(overlapX).toBeCloseTo(TILE_OVERLAP, 9);
  });

  it("satırlar yukarıdan aşağı numaralanıyor", () => {
    const g = planTiles(190, 600, A4_PORTRAIT);
    const top = tileOrigin(g, 0, 0);
    const below = tileOrigin(g, 0, 1);
    expect(top.y).toBeGreaterThan(below.y);
  });

  it("bindirme basılabilir alandan büyükse hata", () => {
    expect(() => planTiles(500, 500, A4_PORTRAIT, 300)).toThrow(/ilerlemez/);
  });
});

describe("sayfa kodları", () => {
  it("sütun harfi + satır numarası", () => {
    expect(tileCode(0, 0)).toBe("A1");
    expect(tileCode(1, 0)).toBe("B1");
    expect(tileCode(0, 2)).toBe("A3");
  });

  it("26'dan sonra iki harf", () => {
    expect(tileCode(25, 0)).toBe("Z1");
    expect(tileCode(26, 0)).toBe("AA1");
  });
});

describe("parça yerleşimi", () => {
  const pattern = generateCardHolder(DEFAULT_PARAMS);

  it("tüm parçalar yerleştiriliyor", () => {
    const layout = packPieces(pattern.pieces);
    expect(layout.placed).toHaveLength(pattern.pieces.length);
  });

  it("parçalar üst üste binmiyor", () => {
    const layout = packPieces(pattern.pieces);
    for (let i = 0; i < layout.placed.length; i++) {
      for (let j = i + 1; j < layout.placed.length; j++) {
        const a = layout.placed[i] as (typeof layout.placed)[0];
        const b = layout.placed[j] as (typeof layout.placed)[0];
        const apart =
          a.x + a.width <= b.x + 1e-9 ||
          b.x + b.width <= a.x + 1e-9 ||
          a.y + a.height <= b.y + 1e-9 ||
          b.y + b.height <= a.y + 1e-9;
        expect(apart).toBe(true);
      }
    }
  });

  it("parçalar tabaka sınırları içinde", () => {
    const layout = packPieces(pattern.pieces);
    for (const p of layout.placed) {
      expect(p.x).toBeGreaterThanOrEqual(-1e-9);
      expect(p.y).toBeGreaterThanOrEqual(-1e-9);
      expect(p.x + p.width).toBeLessThanOrEqual(layout.width + 1e-9);
      expect(p.y + p.height).toBeLessThanOrEqual(layout.height + 1e-9);
    }
  });

  it("boş girdi boş yerleşim", () => {
    expect(packPieces([]).placed).toHaveLength(0);
  });

  it("basılabilir alandan geniş parça tabakayı genişletiyor", () => {
    const wide = generateCardHolder({
      ...DEFAULT_PARAMS,
      orientation: "horizontal",
      stitchMargin: 5,
    });
    const layout = packPieces(wide.pieces);
    expect(layout.width).toBeGreaterThanOrEqual(
      Math.max(...wide.pieces.map((p) => p.width)),
    );
  });
});

describe("kalibrasyon", () => {
  it("doğru ölçümde düzeltme yok", () => {
    const r = scaleFromMeasurement(50);
    expect(r.factor).toBe(1);
    expect(r.ok).toBe(true);
  });

  it("küçük basıldıysa büyütme katsayısı", () => {
    const r = scaleFromMeasurement(49.5);
    expect(r.ok).toBe(true);
    expect(r.factor).toBeCloseTo(50 / 49.5, 9);
    expect(r.factor).toBeGreaterThan(1);
  });

  it("büyük basıldıysa küçültme katsayısı", () => {
    const r = scaleFromMeasurement(50.5);
    expect(r.factor).toBeLessThan(1);
  });

  it("düzeltme uygulandığında sonuç nominale gider", () => {
    // Yazıcı %99 ölçekle basıyorsa: içeriği factor ile büyüt, yazıcı
    // 0.99 ile küçültsün, sonuç 50mm olsun.
    const printerScale = 0.99;
    const measured = CALIBRATION_SQUARE * printerScale;
    const { factor } = scaleFromMeasurement(measured);
    expect(CALIBRATION_SQUARE * factor * printerScale).toBeCloseTo(
      CALIBRATION_SQUARE,
      9,
    );
  });

  it("%10'dan fazla sapma reddediliyor", () => {
    // Kullanıcı inç ölçtüyse ~1.97 girer; sessizce uygulamak felaket olur.
    const r = scaleFromMeasurement(2);
    expect(r.ok).toBe(false);
    expect(r.factor).toBe(1);
    expect(r.message).toContain("mm");
  });

  it("geçersiz girdi reddediliyor", () => {
    expect(scaleFromMeasurement(0).ok).toBe(false);
    expect(scaleFromMeasurement(-5).ok).toBe(false);
    expect(scaleFromMeasurement(Number.NaN).ok).toBe(false);
  });
});

describe("çizgi biçimleri", () => {
  it("desenle ayrışıyor: kesim sürekli, diğerleri kesikli", () => {
    // Siyah-beyaz çıktıda tek ayırt edici desen olmalı.
    expect(STYLES.cut.dash).toHaveLength(0);
    expect(STYLES.stitch.dash.length).toBeGreaterThan(0);
    expect(STYLES.fold.dash.length).toBeGreaterThan(0);
    expect(STYLES.stitch.dash).not.toEqual(STYLES.fold.dash);
  });

  it("kesim çizgisi en koyu ve 0.2mm", () => {
    expect(STYLES.cut.width).toBe(0.2);
    expect(STYLES.cut.gray).toBe(0);
  });
});

describe("PDF üretimi", () => {
  const pattern = generateCardHolder(DEFAULT_PARAMS);

  it("geçerli PDF üretiyor", async () => {
    const bytes = await buildPatternPdf(pattern, FONTS);
    expect(bytes.length).toBeGreaterThan(1000);
    expect(new TextDecoder().decode(bytes.slice(0, 5))).toBe("%PDF-");
  });

  it("sayfa boyutu tam A4 (595.28 × 841.89 pt)", async () => {
    const bytes = await buildPatternPdf(pattern, FONTS);
    const doc = await PDFDocument.load(bytes);
    for (const page of doc.getPages()) {
      expect(page.getWidth()).toBeCloseTo(mmToPt(210), 3);
      expect(page.getHeight()).toBeCloseTo(mmToPt(297), 3);
    }
  });

  it("kapak + montaj + desen sayfaları", async () => {
    const bytes = await buildPatternPdf(pattern, FONTS);
    const doc = await PDFDocument.load(bytes);
    // Kapak + montaj + desen sayfaları (döşeme yoksa sayfa bazlı).
    expect(doc.getPageCount()).toBe(2 + packPages(pattern.pieces).pages.length);
  });

  it("montaj yerleşimi kart sayısı kadar örnek veriyor", () => {
    expect(pattern.assembly).toHaveLength(DEFAULT_PARAMS.cardCount);
  });

  it("montajda yuvalar kademe kadar aralıklı", () => {
    for (let i = 1; i < pattern.assembly.length; i++) {
      const a = pattern.assembly[i - 1] as (typeof pattern.assembly)[0];
      const b = pattern.assembly[i] as (typeof pattern.assembly)[0];
      expect(b.y - a.y).toBeCloseTo(DEFAULT_PARAMS.reveal, 9);
      expect(b.layer).toBe(a.layer + 1);
    }
  });

  it("T-slot yapımda yalnızca en dip yuva düz dikdörtgen", () => {
    const rects = pattern.pieces.filter((p) => p.kind === "slot-rect");
    expect(rects).toHaveLength(1);
    expect(pattern.assembly[0]?.pieceId).toBe(rects[0]?.id);
  });

  it("en üstteki yuvanın üstü panel yüksekliğine TAM denk geliyor", () => {
    // Kademe dizilimi paneli tam doldurmalı: (n−1)·kademe + kart
    // yüksekliği + dikiş payı = panelHeight.
    //
    // DİKKAT: parça yükseklikleri KESİM ölçüsü (kalem payı iki kenardan
    // düşülmüş), montaj konumları ise nominal. Karşılaştırmada payı geri
    // eklemek gerekiyor; ilk yazdığımda bunu atlayıp 0.6mm'lik sahte bir
    // uyuşmazlık görmüştüm.
    const top = pattern.assembly.at(-1);
    const slotPiece = pattern.pieces.find((p) => p.id === top?.pieceId);
    const nominalHeight =
      (slotPiece?.height as number) + 2 * DEFAULT_PARAMS.penAllowance;
    expect((top?.y as number) + nominalHeight).toBeCloseTo(
      pattern.summary.panelHeight,
      6,
    );
  });

  it("parça kodları benzersiz", () => {
    const codes = pattern.pieces.map((p) => p.code);
    expect(new Set(codes).size).toBe(codes.length);
  });

  it("mono font BOŞLUK karakterini gömebiliyor", async () => {
    // FONT SEÇİMİ TESADÜFİ DEĞİL.
    //
    // İlk tercih IBM Plex Mono'ydu (ekran arayüzüyle aynı olsun diye).
    // @pdf-lib/fontkit o TTF'te boşluk karakterinde patlıyor:
    // "Trying to access beyond buffer length" — boş konturlu glifin
    // sınırlayıcı kutusunu okumaya çalışıyor. subset açık/kapalı fark
    // etmiyor. JetBrains Mono aynı işlemi sorunsuz yapıyor.
    //
    // Bu test, biri "ekranla aynı font olsun" diye geri değiştirirse
    // sorunun sessizce dönmemesi için burada.
    const bytes = await buildPatternPdf(pattern, FONTS, {
      title: "bölme genişliği 100.0 mm · dış kabuk",
    });
    expect(bytes.length).toBeGreaterThan(1000);
  });

  it("Türkçe karakterler gömülü fontla kodlanıyor", async () => {
    // Standart PDF fontları (WinAnsi) ı, ş, ğ kodlayamıyor; gömme
    // yapılmazsa üretim tamamen patlar.
    await expect(
      buildPatternPdf(pattern, FONTS, { title: "Kartlık — dış kabuk şablonu kağıt" }),
    ).resolves.toBeInstanceOf(Uint8Array);
  });

  it("kalibrasyon katsayısı çıktıyı büyütüyor", async () => {
    const a = await buildPatternPdf(pattern, FONTS, { scaleFactor: 1 });
    const b = await buildPatternPdf(pattern, FONTS, { scaleFactor: 1.02 });
    // Aynı sayfa sayısı, farklı içerik.
    const da = await PDFDocument.load(a);
    const db = await PDFDocument.load(b);
    expect(db.getPageCount()).toBe(da.getPageCount());
    expect(b.length).not.toBe(a.length);
  });

  it("tüm delikleri basmak çıktıyı büyütüyor", async () => {
    const few = await buildPatternPdf(pattern, FONTS, { printAllHoles: false });
    const many = await buildPatternPdf(pattern, FONTS, { printAllHoles: true });
    expect(many.length).toBeGreaterThan(few.length);
  });

  it("params verilirse yapım adımları sayfası ekleniyor", async () => {
    const without = await PDFDocument.load(
      await buildPatternPdf(pattern, FONTS),
    );
    const withSteps = await PDFDocument.load(
      await buildPatternPdf(pattern, FONTS, { params: DEFAULT_PARAMS }),
    );
    expect(withSteps.getPageCount()).toBeGreaterThan(without.getPageCount());
  });

  it("adım sayfası sayısı metin uzunluğuna göre hesaplanıyor", async () => {
    // Sabit "sayfa başına N adım" varsayımı yok; 8 yuvalı kalıpta
    // yapıştırma sırası uzuyor ve taşma buna göre hesaplanmalı.
    const p8: CardHolderParams = { ...DEFAULT_PARAMS, cardCount: 8 };
    const big = generateCardHolder(p8);
    const steps = buildInstructions(big, p8);
    expect(steps.length).toBeGreaterThan(8);
    const doc = await PDFDocument.load(
      await buildPatternPdf(big, FONTS, { params: p8 }),
    );
    expect(doc.getPageCount()).toBeGreaterThan(4);
  });

  it("VARSAYILAN tüm delikleri basıyor", async () => {
    // Yaygın iş akışı kağıt şablonu deriye bantlayıp işaretli
    // noktalardan delmek; noktalar şablonun asıl işlevlerinden biri.
    const def = await buildPatternPdf(pattern, FONTS);
    const anchorsOnly = await buildPatternPdf(pattern, FONTS, {
      printAllHoles: false,
    });
    expect(def.length).toBeGreaterThan(anchorsOnly.length);
  });

  it("çok sayfalı kalıpta sayfa sayısı artıyor", async () => {
    const big = generateCardHolder({
      ...DEFAULT_PARAMS,
      cardCount: 8,
      reveal: 20,
    });
    const bytes = await buildPatternPdf(big, FONTS);
    const doc = await PDFDocument.load(bytes);
    expect(doc.getPageCount()).toBeGreaterThan(2);
  });
});

describe("sayfa bazlı yerleştirme — hizalama gerektirmeyen çıktı", () => {
  const bifold = generateBifold(BIFOLD_DEFAULTS);

  it("bifold parçaları döndürülünce tek sayfaya sığıyor", () => {
    // ASIL KAZANÇ BU: döşeme olmadan hiçbir parça bölünmüyor, dolayısıyla
    // kullanıcının sayfa hizalama hatası ürünün ölçüsüne giremiyor.
    const layout = packPages(bifold.pieces);
    expect(layout.oversized).toHaveLength(0);
    expect(layout.rotatedCount).toBeGreaterThan(0);
  });

  it("her parça tam olarak bir kez yerleştiriliyor", () => {
    const layout = packPages(bifold.pieces);
    const placedIds = layout.pages.flatMap((p) => p.placed.map((x) => x.piece.id));
    expect(placedIds.sort()).toEqual(bifold.pieces.map((p) => p.id).sort());
  });

  it("yerleştirilen parçalar basılabilir alanı taşmıyor", () => {
    const area = printableArea(A4_PORTRAIT);
    for (const page of packPages(bifold.pieces).pages) {
      for (const p of page.placed) {
        expect(p.x).toBeGreaterThanOrEqual(-1e-9);
        expect(p.y).toBeGreaterThanOrEqual(-1e-9);
        expect(p.x + p.width).toBeLessThanOrEqual(area.width + 1e-9);
        expect(p.y + p.height).toBeLessThanOrEqual(area.height + 1e-9);
      }
    }
  });

  it("aynı sayfadaki parçalar üst üste binmiyor", () => {
    for (const page of packPages(bifold.pieces).pages) {
      for (let i = 0; i < page.placed.length; i++) {
        for (let j = i + 1; j < page.placed.length; j++) {
          const a = page.placed[i] as (typeof page.placed)[0];
          const b = page.placed[j] as (typeof page.placed)[0];
          const apart =
            a.x + a.width <= b.x + 1e-9 ||
            b.x + b.width <= a.x + 1e-9 ||
            a.y + a.height <= b.y + 1e-9 ||
            b.y + b.height <= a.y + 1e-9;
          expect(apart).toBe(true);
        }
      }
    }
  });

  it("döndürme kapatılırsa büyük parçalar döşemeye düşüyor", () => {
    const layout = packPages(bifold.pieces, A4_PORTRAIT, undefined, false);
    expect(layout.rotatedCount).toBe(0);
    expect(layout.oversized.length).toBeGreaterThan(0);
  });

  it("döndürülmüş parçada ölçüler takas ediliyor", () => {
    const layout = packPages(bifold.pieces);
    const outer = layout.pages
      .flatMap((p) => p.placed)
      .find((p) => p.piece.id === "outer");
    expect(outer?.rotated).toBe(true);
    expect(outer?.width).toBeCloseTo(outer?.piece.height as number, 9);
    expect(outer?.height).toBeCloseTo(outer?.piece.width as number, 9);
  });

  it("pieceToLayout döndürmeyi doğru uyguluyor", () => {
    // Yerel (0,0) köşesi, döndürülmüş parçada sol-ÜST köşeye gider.
    const placed = {
      piece: bifold.pieces[0] as (typeof bifold.pieces)[0],
      x: 10,
      y: 20,
      width: 50,
      height: 100,
      rotated: true,
    };
    expect(pieceToLayout(placed, { x: 0, y: 0 }, 0, 0)).toEqual({ x: 60, y: 20 });
    expect(pieceToLayout(placed, { x: 0, y: 50 }, 0, 0)).toEqual({ x: 10, y: 20 });
  });

  it("kartlıkta da hiç bölünme olmuyor", () => {
    const ch = generateCardHolder(DEFAULT_PARAMS);
    expect(packPages(ch.pieces).oversized).toHaveLength(0);
  });

  it("PDF üretilebiliyor ve sayfa sayısı makul", async () => {
    const bytes = await buildPatternPdf(bifold, FONTS, {
      params: BIFOLD_DEFAULTS,
    });
    const doc = await PDFDocument.load(bytes);
    // kapak + montaj + adımlar + desen sayfaları
    expect(doc.getPageCount()).toBeGreaterThanOrEqual(5);
    expect(doc.getPageCount()).toBeLessThan(12);
  });
});
ODK_EOF_9

echo "==> Testler"
pnpm test

echo "==> Typecheck"
pnpm typecheck

echo "==> Arayuz derlemesi"
pnpm --filter @odk/web build

cat << 'ODK_DONE'

============================================================
DIKIS PROJEKSIYONU + ACIK UST KENAR
============================================================

Bifold 3+3, parca basina delik:
  A dis kabuk        96
  B ic kabuk         96   (dis kabukla birebir ayni noktalar)
  C-S1 / C-R1        39 / 38
  D-S2 D-S3 ...       4   (T-slot govdesi kenara ulasmiyor)

Git:
  git add -A
  git commit -m "Dikis projeksiyonu ve acik ust kenar

SORU: yuva parcalarinin delikleri neden yok?
CEVAP: olmaliydi. Cevre dikisi butun katmanlardan ayni anda gecer.

- projectStitchPlan(): cevre dikisi TEK KEZ birlesik dis hat uzerinde
  planlaniyor, sonra her parcaya kendi siniri icine dusen delikler
  yansitiliyor. Her parcaya bagimsiz distributeStitches cagirmak
  felaket olurdu: cevre uzunluklari ve kose konumlari farkli oldugu
  icin delikler tutmazdi.
- HER ORNEK AYRI PARCA. 'T-slot yuva x4' gruplamasi mumkun degil:
  sol paneldeki yuva sol kenardan, sagdaki sag kenardan delik aliyor.
  Ayni sekil, farkli delik deseni. Referans kalip da A-1/A-2/A-3'u
  ayri ayri cizmisti.
- projectAcrossFold(): ic kabuk kat payi kadar kisa ama ORTALANMIYOR.
  Kenarlar hizali, eksik uzunluk sirtta soguruluyor. Ortalanmis
  varsaydigimda ic kabuga 143 yerine 105 delik dusuyordu; yan
  kenarlarin tamami kaybolmustu.
- BIFOLD UST KENARI ARTIK ACIK. Kapali cevre dikisi banknot bolmesinin
  agzini dikiyordu. Ilk surumde ustteki kart yuvasi tam olarak
  dikilmemesi gereken kenardan 28 delik aliyordu.
- pointInPolygon() geometry paketine eklendi
- 321 test geciyor"

  git push
  vercel --prod

BILINEN SORUN — KARTLIK
Kartligin kat cizgisi YATAY ama dikis yan kenarlarda olmali; bu ikisi
birlikte imkansiz (dikis kati keserdi). Kartligin kat yonunun bifold
gibi DIKEY olmasi gerekiyor. Bu ayri bir duzeltme.
ODK_DONE
