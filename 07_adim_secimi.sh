#!/usr/bin/env bash
#
# 07_adim_secimi.sh — Ilk basilan PDF'ten cikan duzeltmeler
#
# 1) selectPitch tolerans bandi: olculemeyecek sapma farki icin
#    fazladan delik deldirmiyor
# 2) Iron adimi artik kullanici kontrolu (varsayilan 3.85mm)
# 3) Tek segmentli kapali hatta "cevre" deniyor, "1. kenar" degil
#
# Repo kokunde calistir. Idempotent.

set -euo pipefail

if [ ! -f "pnpm-workspace.yaml" ] || [ ! -d "packages/geometry/src/stitch" ]; then
  echo "HATA: Repo kokunde calistirilmali ve 04/05 uygulanmis olmali." >&2
  exit 1
fi

echo "==> packages/geometry/src/stitch/distribute.ts"
cat > packages/geometry/src/stitch/distribute.ts << 'ODK_EOF_0'
import type { Mm } from "../units.js";
import { EPS, IRON_PITCHES } from "../units.js";
import type { Vec } from "../vec.js";
import type { Polyline } from "../path/path.js";
import {
  buildArcLengthTable,
  pointAtDistance,
  tangentAtDistance,
  findCorners,
  spansBetweenCorners,
} from "../path/arclength.js";
import type { ArcLengthTable, Span } from "../path/arclength.js";

/**
 * DİKİŞ DELİĞİ DAĞITICI
 *
 * ═══════════════════════════════════════════════════════════════════════
 * ÜÇ KISIT AYNI ANDA
 * ═══════════════════════════════════════════════════════════════════════
 *
 * 1) KÖŞEDE DELİK OLMAK ZORUNDA.
 *    Köşede delik yoksa iplik dönüşü bozulur ve kenar buruşur. Bu yüzden
 *    köşeler "çapa" kabul edilir ve delik dağıtımı köşeler arasında
 *    bağımsız yapılır.
 *
 * 2) ADIM SERBEST DEĞİL.
 *    Kullanıcının elindeki pricking iron sabit adımlıdır (2.7 / 3.0 /
 *    3.38 / 3.85 / 4.0 / 5.0mm). Kenarı tam bölen keyfi bir adım
 *    üretmek işe yaramaz — o takım yok.
 *
 * 3) SEGMENT UZUNLUĞU ADIMA TAM BÖLÜNMEZ.
 *    Çözüm: adımı değiştirmek yerine delik sayısını yuvarlayıp gerçek
 *    adımı L/n olarak kabul etmek. Kalan sapma delik başına dağılır.
 *
 * ═══════════════════════════════════════════════════════════════════════
 * ADIM SEÇİMİ GLOBAL YAPILIR
 * ═══════════════════════════════════════════════════════════════════════
 *
 * Her segment için ayrı ayrı "en iyi adım" seçmek yanlış olur: tek bir
 * parçada iki farklı iron kullanılamaz. Bu yüzden aday adımların her biri
 * TÜM segmentlerde denenir ve en kötü segmentteki sapmayı en küçük yapan
 * adım seçilir (minimax). Bu, kullanıcının tek takımla en tutarlı sonucu
 * almasını sağlar.
 */

export interface StitchHole {
  readonly position: Vec;
  /** İlerleme yönü. Deliğin eğimini çizmek ve normal hesaplamak için. */
  readonly tangent: Vec;
  /** Yol başından bu deliğe kadarki mesafe. */
  readonly distance: Mm;
  readonly spanIndex: number;
  /** Köşe çapası mı? Bu delikler kaydırılamaz. */
  readonly isAnchor: boolean;
}

export interface StitchSpanPlan {
  readonly index: number;
  readonly startDistance: Mm;
  readonly endDistance: Mm;
  readonly length: Mm;
  /** Bu segmentteki delik aralığı sayısı (delik sayısı = intervals + 1). */
  readonly intervals: number;
  readonly actualPitch: Mm;
  /** Nominal adımdan sapma. 0.15mm üstü gözle görülür. */
  readonly deviation: Mm;
}

export interface StitchPlan {
  readonly holes: readonly StitchHole[];
  readonly spans: readonly StitchSpanPlan[];
  /** Kullanılacak fiziksel iron adımı. */
  readonly pitch: Mm;
  readonly totalHoles: number;
  readonly maxDeviation: Mm;
  readonly warnings: readonly string[];
}

export interface StitchOptions {
  /**
   * Kullanılacak adım. Verilmezse aday listesinden minimax ile seçilir.
   */
  readonly pitch?: Mm;
  /** Adım seçimi için adaylar. */
  readonly candidatePitches?: readonly Mm[];
  /** Köşe sayılma eşiği (derece). */
  readonly cornerAngleDeg?: number;
  /** Bu sapmanın üstünde uyarı üretilir. */
  readonly deviationLimit?: Mm;
}

/** Segment için delik aralığı sayısı ve gerçek adım. */
function fitSpan(length: Mm, pitch: Mm): { intervals: number; actualPitch: Mm } {
  const intervals = Math.max(1, Math.round(length / pitch));
  return { intervals, actualPitch: length / intervals };
}

/**
 * Sapma farkının anlamsız sayıldığı bant.
 *
 * 0.05mm, baskı hassasiyetimizle ve el kesim hata payıyla aynı
 * mertebede. Bu bandın içindeki iki adım fiziksel olarak ayırt
 * edilemez, dolayısıyla aralarında sapmaya bakarak seçim yapmak
 * anlamsızdır.
 */
export const PITCH_TIE_BAND: Mm = 0.05;

/**
 * Aday adımlar arasından seçim.
 *
 * İKİ AŞAMALI, ÇÜNKÜ TEK ÖLÇÜT YETMİYOR:
 *
 * Önce en kötü segmentteki sapmayı en küçük yapan adım bulunur. Sonra
 * bu değerin PITCH_TIE_BAND kadar yakınındaki TÜM adaylar arasından
 * EN BÜYÜĞÜ seçilir.
 *
 * NEDEN: ilk sürümde yalnızca sapma minimize ediliyordu ve gerçek bir
 * çıktıda 559.2mm'lik bir çevre için 2.7mm adım seçildi — 207 delik.
 * Oysa adayların hepsi 0.01mm'nin altında sapma veriyordu; 3.85mm ile
 * 145 delik çıkıyordu. Yani algoritma ölçülemeyecek kadar küçük bir
 * "kazanç" için kullanıcıya 62 fazla delik deldiriyordu.
 *
 * Uzun kenarlarda neredeyse her adım küçük sapma verir; ölçüt
 * dejenere olur ve seçim rastgeleye döner. Bant, o durumda emeği
 * azaltan tarafa karar verir.
 */
export function selectPitch(
  spans: readonly Span[],
  candidates: readonly Mm[] = IRON_PITCHES,
): Mm {
  if (candidates.length === 0) {
    throw new Error("selectPitch: aday adım listesi boş.");
  }

  const scored = candidates.map((pitch) => {
    let worst = 0;
    for (const span of spans) {
      const { actualPitch } = fitSpan(span.length, pitch);
      worst = Math.max(worst, Math.abs(actualPitch - pitch));
    }
    return { pitch, worst };
  });

  const bestWorst = Math.min(...scored.map((s) => s.worst));
  const acceptable = scored.filter((s) => s.worst <= bestWorst + PITCH_TIE_BAND);

  return acceptable.reduce((a, b) => (b.pitch > a.pitch ? b : a)).pitch;
}

/**
 * Kapalı ya da açık bir yol üzerine dikiş deliklerini dağıtır.
 *
 * Köşe çapaları arasında eşit aralıklı yerleşim yapılır. Kapalı yolda
 * son segmentin bitiş deliği ilk segmentin başlangıç deliğiyle aynı
 * noktadır ve iki kez üretilmez.
 */
export function distributeStitches(
  poly: Polyline,
  closed: boolean,
  options: StitchOptions = {},
): StitchPlan {
  const warnings: string[] = [];
  const deviationLimit = options.deviationLimit ?? 0.15;

  const table = buildArcLengthTable(poly, closed);
  if (table.totalLength <= EPS) {
    return {
      holes: [],
      spans: [],
      pitch: options.pitch ?? (IRON_PITCHES[0] as Mm),
      totalHoles: 0,
      maxDeviation: 0,
      warnings: ["Yol uzunluğu sıfır; delik dağıtılamaz."],
    };
  }

  const corners = findCorners(table, options.cornerAngleDeg ?? 25);
  const spans = spansBetweenCorners(table, corners);

  const pitch =
    options.pitch ?? selectPitch(spans, options.candidatePitches ?? IRON_PITCHES);

  const spanPlans: StitchSpanPlan[] = [];
  const holes: StitchHole[] = [];
  let maxDeviation = 0;

  for (let s = 0; s < spans.length; s++) {
    const span = spans[s] as Span;
    const { intervals, actualPitch } = fitSpan(span.length, pitch);
    const deviation = Math.abs(actualPitch - pitch);
    maxDeviation = Math.max(maxDeviation, deviation);

    spanPlans.push({
      index: s,
      startDistance: span.startDistance,
      endDistance: span.endDistance,
      length: span.length,
      intervals,
      actualPitch,
      deviation,
    });

    if (span.length < pitch - EPS) {
      warnings.push(
        `${s + 1}. kenar (${span.length.toFixed(1)}mm) seçilen ${pitch}mm adımdan kısa; ` +
          `tek aralığa zorlandı ve gerçek adım ${actualPitch.toFixed(2)}mm oldu.`,
      );
    }
    if (deviation > deviationLimit) {
      warnings.push(
        `${s + 1}. kenarda adım sapması ${deviation.toFixed(2)}mm ` +
          `(sınır ${deviationLimit}mm). Bu kenarda delikler gözle fark edilir ölçüde kayabilir.`,
      );
    }

    // i = intervals atlanır: o nokta bir sonraki segmentin çapası.
    // Açık yolda son segmentin bitişi ayrıca eklenir.
    for (let i = 0; i < intervals; i++) {
      const d = span.startDistance + i * actualPitch;
      holes.push(makeHole(table, d, s, i === 0));
    }
  }

  if (!closed) {
    holes.push(
      makeHole(table, table.totalLength, Math.max(0, spans.length - 1), true),
    );
  }

  return {
    holes,
    spans: spanPlans,
    pitch,
    totalHoles: holes.length,
    maxDeviation,
    warnings,
  };
}

function makeHole(
  table: ArcLengthTable,
  d: Mm,
  spanIndex: number,
  isAnchor: boolean,
): StitchHole {
  return {
    position: pointAtDistance(table, d),
    tangent: tangentAtDistance(table, d),
    distance: d,
    spanIndex,
    isAnchor,
  };
}

/**
 * Kullanıcıya basılacak özet.
 *
 * Elle kesen kullanıcı delikleri pricking iron ile kendisi yürüyor;
 * yüzlerce noktayı tek tek basmak yerine "bu kenarda kaç delik" bilgisi
 * daha kullanışlı ve daha hassas. Bu fonksiyon o metni üretir.
 */
export function stitchSummary(plan: StitchPlan): string[] {
  // Köşesi yuvarlatılmış kapalı bir hatta tek segment kalır; ona
  // "1. kenar" demek yanıltıcı olur, o segment çevrenin tamamıdır.
  const singleClosed = plan.spans.length === 1;

  return plan.spans.map((s) => {
    const label = singleClosed ? "çevre" : `${s.index + 1}. kenar`;
    return (
      `${label}: ${s.length.toFixed(1)}mm, ` +
      `${s.intervals} aralık, gerçek adım ${s.actualPitch.toFixed(2)}mm` +
      (s.deviation > 0.05 ? ` (sapma ${s.deviation.toFixed(2)}mm)` : "")
    );
  });
}
ODK_EOF_0

echo "==> packages/geometry/src/stitch/stitch.test.ts"
cat > packages/geometry/src/stitch/stitch.test.ts << 'ODK_EOF_1'
import { describe, it, expect } from "vitest";
import { vec, distance, vecEq } from "../vec.js";
import { path, flattenPath, bbox, polylineLength } from "../path/path.js";
import { buildArcLengthTable, findCorners } from "../path/arclength.js";
import { IRON_PITCHES } from "../units.js";
import { roundCorners, suggestedStitchCornerRadius } from "./corners.js";
import {
  distributeStitches,
  selectPitch,
  stitchSummary,
} from "./distribute.js";

function rect(w: number, h: number) {
  return flattenPath(
    path()
      .moveTo(vec(0, 0))
      .lineTo(vec(w, 0))
      .lineTo(vec(w, h))
      .lineTo(vec(0, h))
      .close(),
  );
}

const R100x50 = rect(100, 50);

describe("roundCorners", () => {
  it("dikdörtgenin 4 köşesini yaya çevirir", () => {
    const r = roundCorners(R100x50, true, { radius: 5, arcSegments: 8 });
    // Her köşe 9 noktalı yaya dönüşür (8 segment).
    expect(r.length).toBe(4 * 9);
  });

  it("yuvarlatılmış şekil orijinalin içinde kalır", () => {
    const r = roundCorners(R100x50, true, { radius: 5 });
    const b = bbox(r);
    expect(b.min.x).toBeGreaterThanOrEqual(-1e-9);
    expect(b.min.y).toBeGreaterThanOrEqual(-1e-9);
    expect(b.max.x).toBeLessThanOrEqual(100 + 1e-9);
    expect(b.max.y).toBeLessThanOrEqual(50 + 1e-9);
  });

  it("çevre kısalır ve segment sayısı arttıkça teorik değere yakınsar", () => {
    const before = polylineLength(R100x50, true);
    // Teorik kayıp: 4 köşede 4 × (2r − πr/2) = 4 × (10 − 7.854) = 8.584mm
    const theoretical = 4 * (10 - (Math.PI * 5) / 2);

    const loss = (segments: number) =>
      before -
      polylineLength(
        roundCorners(R100x50, true, { radius: 5, arcSegments: segments }),
        true,
      );

    // Kirişler yaydan kısa olduğu için kaba yaklaşım kaybı FAZLA gösterir.
    // Ölçülen: 4 -> 8.786, 8 -> 8.635, 12 -> 8.606, 64 -> 8.5849, 256 -> 8.5841
    expect(loss(4)).toBeGreaterThan(loss(8));
    expect(loss(8)).toBeGreaterThan(loss(12));
    expect(loss(12)).toBeGreaterThan(loss(64));
    expect(loss(256)).toBeCloseTo(theoretical, 3);

    // Varsayılan segment sayısındaki hata bütçemizin çok altında.
    const withDefault =
      before - polylineLength(roundCorners(R100x50, true, { radius: 5 }), true);
    expect(Math.abs(withDefault - theoretical)).toBeLessThan(0.05);
  });

  it("yarıçap sıfırsa şekil değişmez", () => {
    expect(roundCorners(R100x50, true, { radius: 0 })).toEqual(R100x50);
  });

  it("kenara sığmayan yarıçap otomatik küçültülür", () => {
    // 6mm yüksekliğinde şeritte 20mm yarıçap istenirse taşmamalı.
    const thin = rect(100, 6);
    const r = roundCorners(thin, true, { radius: 20 });
    const b = bbox(r);
    expect(b.height).toBeLessThanOrEqual(6 + 1e-9);
    expect(b.width).toBeLessThanOrEqual(100 + 1e-9);
  });

  it("yumuşak dönüşleri yuvarlatmaz", () => {
    // Neredeyse düz bir kırılma köşe sayılmamalı.
    const almostStraight = [vec(0, 0), vec(50, 0.2), vec(100, 0)];
    const r = roundCorners(almostStraight, false, { radius: 5, minAngleDeg: 25 });
    expect(r).toHaveLength(3);
  });

  it("açık yolda uç noktalar korunur", () => {
    const open = [vec(0, 0), vec(50, 0), vec(50, 50)];
    const r = roundCorners(open, false, { radius: 5 });
    expect(vecEq(r[0] as ReturnType<typeof vec>, vec(0, 0))).toBe(true);
    expect(vecEq(r.at(-1) as ReturnType<typeof vec>, vec(50, 50))).toBe(true);
  });

  it("ADIM 5 BULGUSUNU ÇÖZÜYOR: keskin köşe artık köşe olarak görünmüyor", () => {
    // İçe ötelenmiş dikiş hattında 4 keskin köşe vardı; yuvarlatma
    // sonrası delik dağıtıcısı orada kırılma görmemeli.
    const sharpCorners = findCorners(buildArcLengthTable(R100x50, true), 25);
    expect(sharpCorners).toHaveLength(4);

    const rounded = roundCorners(R100x50, true, { radius: 5, arcSegments: 12 });
    const roundedCorners = findCorners(buildArcLengthTable(rounded, true), 25);
    expect(roundedCorners).toHaveLength(0);
  });
});

describe("suggestedStitchCornerRadius", () => {
  it("dikiş payına eşit", () => {
    expect(suggestedStitchCornerRadius(3.5)).toBe(3.5);
  });
});

describe("selectPitch — minimax", () => {
  it("100mm tek kenarda tam bölen adımı seçer", () => {
    const spans = [{ startDistance: 0, endDistance: 100, length: 100 }];
    const pitch = selectPitch(spans);
    expect(100 / pitch).toBeCloseTo(Math.round(100 / pitch), 6);
  });

  it("seçilen adım aday listesinden biri", () => {
    const spans = [
      { startDistance: 0, endDistance: 93, length: 93 },
      { startDistance: 93, endDistance: 136, length: 43 },
    ];
    expect(IRON_PITCHES).toContain(selectPitch(spans));
  });

  it("sapmalar ayırt edilemez olduğunda EN BÜYÜK adımı seçiyor", () => {
    // Gerçek çıktıdan gelen vaka: 559.2mm çevre, tüm adaylar 0.01mm
    // altında sapma veriyor. Sadece sapmaya bakan seçim 2.7mm (207
    // delik) seçiyordu; 3.85mm ile 145 delik çıkıyor ve fark ölçülemez.
    const spans = [{ startDistance: 0, endDistance: 559.2, length: 559.2 }];
    const chosen = selectPitch(spans);
    expect(chosen).toBe(5.0);

    // Tüm adayların sapması gerçekten ihmal edilebilir mi?
    for (const p of IRON_PITCHES) {
      const n = Math.round(559.2 / p);
      expect(Math.abs(559.2 / n - p)).toBeLessThan(0.01);
    }
  });

  it("sapma bandın dışındaysa büyük adım seçilmiyor", () => {
    // 43mm kenarda adımlar arasında gerçek fark var; burada kalite
    // emekten önce gelir.
    const spans = [{ startDistance: 0, endDistance: 43, length: 43 }];
    const chosen = selectPitch(spans, [3.85, 5.0]);
    const dev = (p: number) => Math.abs(43 / Math.round(43 / p) - p);
    expect(dev(chosen)).toBeLessThanOrEqual(
      Math.min(dev(3.85), dev(5.0)) + 0.05,
    );
  });

  it("boş aday listesi hata", () => {
    expect(() => selectPitch([{ startDistance: 0, endDistance: 10, length: 10 }], [])).toThrow();
  });

  it("en kötü segmentteki sapmayı bant içinde tutuyor", () => {
    const spans = [
      { startDistance: 0, endDistance: 93, length: 93 },
      { startDistance: 93, endDistance: 136, length: 43 },
      { startDistance: 136, endDistance: 229, length: 93 },
    ];
    const chosen = selectPitch(spans);

    function worstFor(p: number): number {
      return Math.max(
        ...spans.map((s) => {
          const n = Math.max(1, Math.round(s.length / p));
          return Math.abs(s.length / n - p);
        }),
      );
    }
    const chosenWorst = worstFor(chosen);
    const bestWorst = Math.min(...IRON_PITCHES.map(worstFor));
    expect(chosenWorst).toBeLessThanOrEqual(bestWorst + 0.05);
  });
});

describe("distributeStitches — kapalı dikdörtgen", () => {
  const plan = distributeStitches(R100x50, true, { pitch: 4 });

  it("her köşede delik var", () => {
    const anchorDistances = plan.holes
      .filter((h) => h.isAnchor)
      .map((h) => Math.round(h.distance));
    expect(anchorDistances).toEqual([0, 100, 150, 250]);
  });

  it("segment başına delik sayısı round(L/adım)", () => {
    // 100/4 = 25, 50/4 = 12.5 -> 13
    expect(plan.spans.map((s) => s.intervals)).toEqual([25, 13, 25, 13]);
  });

  it("gerçek adım segmenti tam bölüyor", () => {
    for (const s of plan.spans) {
      expect(s.actualPitch * s.intervals).toBeCloseTo(s.length, 9);
    }
  });

  it("segment içinde delikler eşit aralıklı", () => {
    for (let s = 0; s < plan.spans.length; s++) {
      const inSpan = plan.holes.filter((h) => h.spanIndex === s);
      for (let i = 1; i < inSpan.length; i++) {
        const d = distance(
          (inSpan[i - 1] as (typeof inSpan)[0]).position,
          (inSpan[i] as (typeof inSpan)[0]).position,
        );
        expect(d).toBeCloseTo(
          (plan.spans[s] as (typeof plan.spans)[0]).actualPitch,
          6,
        );
      }
    }
  });

  it("kapalı yolda başlangıç deliği iki kez üretilmiyor", () => {
    const total = plan.spans.reduce((a, s) => a + s.intervals, 0);
    expect(plan.totalHoles).toBe(total);
    // Aynı konumda iki delik olmamalı.
    for (let i = 0; i < plan.holes.length; i++) {
      for (let j = i + 1; j < plan.holes.length; j++) {
        const a = plan.holes[i] as (typeof plan.holes)[0];
        const b = plan.holes[j] as (typeof plan.holes)[0];
        expect(distance(a.position, b.position)).toBeGreaterThan(0.01);
      }
    }
  });

  it("teğetler kenar yönünü veriyor", () => {
    const onBottom = plan.holes.find((h) => h.spanIndex === 0 && h.distance > 20);
    expect(vecEq(onBottom?.tangent as ReturnType<typeof vec>, vec(1, 0), 0.01)).toBe(
      true,
    );
  });

  it("50mm kenarda 4mm adım 0.15mm sınırını aşıyor ve uyarı üretiyor", () => {
    // 50/13 = 3.846 -> sapma 0.154mm
    const s = plan.spans[1];
    expect(s?.deviation).toBeCloseTo(0.154, 3);
    expect(plan.warnings.some((w) => w.includes("sapma"))).toBe(true);
  });

  it("adım otomatik seçilirse sapma daha küçük olabiliyor", () => {
    const auto = distributeStitches(R100x50, true);
    expect(auto.maxDeviation).toBeLessThanOrEqual(plan.maxDeviation);
    expect(IRON_PITCHES).toContain(auto.pitch);
  });
});

describe("distributeStitches — açık yol", () => {
  const open = [vec(0, 0), vec(40, 0), vec(40, 30)];
  const plan = distributeStitches(open, false, { pitch: 4 });

  it("son nokta da delik alıyor", () => {
    const last = plan.holes.at(-1);
    expect(vecEq(last?.position as ReturnType<typeof vec>, vec(40, 30))).toBe(true);
  });

  it("delik sayısı = aralık toplamı + 1", () => {
    const intervals = plan.spans.reduce((a, s) => a + s.intervals, 0);
    expect(plan.totalHoles).toBe(intervals + 1);
  });
});

describe("distributeStitches — dejenere durumlar", () => {
  it("adımdan kısa kenar tek aralığa zorlanıyor ve uyarı veriyor", () => {
    const tiny = rect(2, 2);
    const plan = distributeStitches(tiny, true, { pitch: 4 });
    for (const s of plan.spans) expect(s.intervals).toBe(1);
    expect(plan.warnings.some((w) => w.includes("kısa"))).toBe(true);
  });

  it("sıfır uzunluklu yol boş plan veriyor, patlamıyor", () => {
    const plan = distributeStitches([vec(5, 5)], true, { pitch: 4 });
    expect(plan.totalHoles).toBe(0);
    expect(plan.warnings).toHaveLength(1);
  });

  it("yuvarlatılmış hatta köşe yok, tek segment olarak dağıtılıyor", () => {
    const rounded = roundCorners(R100x50, true, { radius: 5, arcSegments: 12 });
    const plan = distributeStitches(rounded, true, { pitch: 4 });
    expect(plan.spans).toHaveLength(1);
    expect(plan.totalHoles).toBeGreaterThan(60);
  });
});

describe("stitchSummary", () => {
  it("kenar başına okunabilir satır üretiyor", () => {
    const plan = distributeStitches(R100x50, true, { pitch: 4 });
    const lines = stitchSummary(plan);
    expect(lines).toHaveLength(4);
    expect(lines[0]).toContain("1. kenar");
    expect(lines[0]).toContain("25 aralık");
  });

  it("tek segmentte \"çevre\" diyor, \"1. kenar\" demiyor", () => {
    const rounded = roundCorners(R100x50, true, { radius: 5, arcSegments: 12 });
    const lines = stitchSummary(distributeStitches(rounded, true, { pitch: 4 }));
    expect(lines).toHaveLength(1);
    expect(lines[0]).toContain("çevre");
    expect(lines[0]).not.toContain("kenar");
  });
});
ODK_EOF_1

echo "==> packages/patterns/src/cardholder.ts"
cat > packages/patterns/src/cardholder.ts << 'ODK_EOF_2'
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
  readonly name: string;
  readonly kind: PieceKind;
  readonly quantity: number;
  readonly leatherThickness: Mm;
  /** Basılacak kesim hattı (kalem payı uygulanmış). */
  readonly cutLine: Polyline;
  /** Dikiş hattı — yalnızca çevre dikişi olan parçalarda. */
  readonly stitchLine?: Polyline;
  readonly stitchPlan?: StitchPlan;
  readonly foldLines: readonly FoldLine[];
  readonly width: Mm;
  readonly height: Mm;
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
  readonly totalHoles: number;
  readonly pitch: Mm;
  readonly fitsA4: boolean;
}

export interface PatternResult {
  readonly pieces: readonly PatternPiece[];
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

  // Yuva parçaları.
  const slotPieceHeight = cardH(params.orientation) + params.stitchMargin;
  const mouthHeight = Math.min(params.reveal, slotPieceHeight / 2);
  const sideInset = params.stitchMargin + T_SLOT_WRAP_ALLOWANCE;

  if (slotGeo.rectanglePieces > 0) {
    const nominal = roundCorners(rectangle(0, 0, W, slotPieceHeight), true, {
      radius: Math.min(params.cornerRadius, slotPieceHeight / 4),
    });
    const cut = cutLine(nominal, { penAllowance: params.penAllowance });
    const b = bbox(cut);
    pieces.push({
      id: "slot-rect",
      name: "alt yuva (düz)",
      kind: "slot-rect",
      quantity: slotGeo.rectanglePieces,
      leatherThickness: params.slotThickness,
      cutLine: cut,
      foldLines: [],
      width: b.width,
      height: b.height,
    });
  }

  if (slotGeo.tSlotPieces > 0) {
    const nominal = roundCorners(
      tSlotShape(W, slotPieceHeight, mouthHeight, sideInset),
      true,
      { radius: Math.min(params.cornerRadius, sideInset / 2) },
    );
    const cut = cutLine(nominal, { penAllowance: params.penAllowance });
    const b = bbox(cut);

    // Gövde, dikiş hattının içine girmemeli.
    const neck = narrowestWidth(cut);
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

    pieces.push({
      id: "slot-t",
      name: "T-slot yuva",
      kind: "slot-t",
      quantity: slotGeo.tSlotPieces,
      leatherThickness: params.slotThickness,
      cutLine: cut,
      foldLines: [],
      width: b.width,
      height: b.height,
    });
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
      totalHoles: outerPlan.totalHoles,
      pitch: outerPlan.pitch,
      fitsA4,
    },
  };
}

/** Kart genişliği/yüksekliği dışa açılıyor: arayüz etiketleri için. */
export const cardDimensions = { width: cardW, height: cardH };
ODK_EOF_2

echo "==> apps/web/src/App.tsx"
cat > apps/web/src/App.tsx << 'ODK_EOF_3'
import { useMemo, useState } from "react";
import type {
  CardHolderParams,
  CardOrientation,
  SlotConstruction,
} from "@odk/patterns";
import {
  DEFAULT_PARAMS,
  generateCardHolder,
  stitchSummaryFor,
} from "./engine.js";
import { PieceView } from "./PieceView.js";

/**
 * PDF katmanı DİNAMİK yükleniyor.
 *
 * pdf-lib + fontkit ana pakete girdiğinde bundle 1.29MB'a çıkıyordu.
 * Kullanıcıların çoğu önce parametrelerle oynuyor; PDF kodunu ilk
 * "PDF indir" tıklamasına kadar indirmemek ilk açılışı belirgin
 * hızlandırıyor.
 */
const pdfModule = () => import("./pdf.js");

const PX_PER_MM = 2.4;

interface SliderProps {
  label: string;
  value: number;
  min: number;
  max: number;
  step: number;
  unit?: string;
  hint?: string;
  onChange: (v: number) => void;
}

function Slider({ label, value, min, max, step, unit, hint, onChange }: SliderProps) {
  const id = `f-${label.replace(/\s/g, "-")}`;
  return (
    <div className="field">
      <div className="field-head">
        <label htmlFor={id}>{label}</label>
        <span className="field-value">
          {step < 1 ? value.toFixed(1) : value}
          {unit ?? ""}
        </span>
      </div>
      <input
        id={id}
        type="range"
        min={min}
        max={max}
        step={step}
        value={value}
        onChange={(e) => onChange(Number(e.target.value))}
      />
      {hint !== undefined && <p className="hint">{hint}</p>}
    </div>
  );
}

interface ChoiceProps<T extends string> {
  label: string;
  value: T;
  options: readonly { value: T; label: string }[];
  hint?: string;
  onChange: (v: T) => void;
}

function Choice<T extends string>({
  label,
  value,
  options,
  hint,
  onChange,
}: ChoiceProps<T>) {
  return (
    <div className="field">
      <div className="field-head">
        <label>{label}</label>
      </div>
      <div className="segmented" role="group" aria-label={label}>
        {options.map((o) => (
          <button
            key={o.value}
            type="button"
            aria-pressed={o.value === value}
            onClick={() => onChange(o.value)}
          >
            {o.label}
          </button>
        ))}
      </div>
      {hint !== undefined && <p className="hint">{hint}</p>}
    </div>
  );
}

interface PrintState {
  readonly printAllHoles: boolean;
  readonly measured: string;
  readonly scaleFactor: number;
  readonly note: string;
  readonly noteOk: boolean;
  readonly busy: boolean;
}

const INITIAL_PRINT: PrintState = {
  printAllHoles: false,
  measured: "50",
  scaleFactor: 1,
  note: "",
  noteOk: true,
  busy: false,
};

interface SelectProps {
  label: string;
  value: string;
  options: readonly { value: string; label: string }[];
  hint?: string;
  onChange: (v: string) => void;
}

function Select({ label, value, options, hint, onChange }: SelectProps) {
  const id = `s-${label.replace(/\s/g, "-")}`;
  return (
    <div className="field">
      <div className="field-head">
        <label htmlFor={id}>{label}</label>
      </div>
      <select
        id={id}
        className="dropdown"
        value={value}
        onChange={(e) => onChange(e.target.value)}
      >
        {options.map((o) => (
          <option key={o.value} value={o.value}>
            {o.label}
          </option>
        ))}
      </select>
      {hint !== undefined && <p className="hint">{hint}</p>}
    </div>
  );
}

export default function App() {
  const [params, setParams] = useState<CardHolderParams>(DEFAULT_PARAMS);
  const [print, setPrint] = useState<PrintState>(INITIAL_PRINT);

  const set = <K extends keyof CardHolderParams>(
    key: K,
    value: CardHolderParams[K],
  ) => setParams((p) => ({ ...p, [key]: value }));

  const result = useMemo(() => {
    try {
      return { ok: true as const, value: generateCardHolder(params) };
    } catch (err) {
      return {
        ok: false as const,
        message: err instanceof Error ? err.message : String(err),
      };
    }
  }, [params]);

  return (
    <div className="shell">
      <aside className="rail">
        <header className="masthead">
          <h1>Deri Kalıp Motoru</h1>
          <p>
            Kartlık · kesit çözücü + dikiş dağıtıcı
            <br />
            ölçüler mm · ızgara 10mm, kalın çizgi 50mm
          </p>
        </header>

        <fieldset className="group" style={{ border: 0, margin: 0, padding: 0 }}>
          <legend>Yuvalar</legend>
          <Slider
            label="Kart yuvası"
            value={params.cardCount}
            min={1}
            max={8}
            step={1}
            onChange={(v) => set("cardCount", v)}
          />
          <Choice<SlotConstruction>
            label="Yapım biçimi"
            value={params.construction}
            options={[
              { value: "t-slot", label: "T-slot" },
              { value: "stacked", label: "Düz yığın" },
            ]}
            hint="T-slot kenar kalınlığını yuva sayısından bağımsız tutar."
            onChange={(v) => set("construction", v)}
          />
          <Choice<CardOrientation>
            label="Kart yönü"
            value={params.orientation}
            options={[
              { value: "horizontal", label: "Yatay" },
              { value: "vertical", label: "Dikey" },
            ]}
            onChange={(v) => set("orientation", v)}
          />
          <Slider
            label="Kademe"
            value={params.reveal}
            min={5}
            max={22}
            step={0.5}
            unit="mm"
            hint="Yuva ağızları arası mesafe. 5mm belgelenmiş alt sınır."
            onChange={(v) => set("reveal", v)}
          />
        </fieldset>

        <fieldset className="group" style={{ border: 0, margin: 0, padding: 0 }}>
          <legend>Deri</legend>
          <Slider
            label="Dış kabuk"
            value={params.outerThickness}
            min={0.6}
            max={1.6}
            step={0.1}
            unit="mm"
            onChange={(v) => set("outerThickness", v)}
          />
          <Slider
            label="Yuva derisi"
            value={params.slotThickness}
            min={0.4}
            max={1.2}
            step={0.1}
            unit="mm"
            hint="Önerilen 0.6–0.8mm. Kalın deri yuvanın esnemesini engeller."
            onChange={(v) => set("slotThickness", v)}
          />
        </fieldset>

        <fieldset className="group" style={{ border: 0, margin: 0, padding: 0 }}>
          <legend>Dikiş ve kesim</legend>
          <Select
            label="Pricking iron"
            value={params.pitch === undefined ? "auto" : String(params.pitch)}
            options={[
              { value: "2.7", label: "2.7 mm" },
              { value: "3", label: "3.0 mm" },
              { value: "3.38", label: "3.38 mm" },
              { value: "3.85", label: "3.85 mm" },
              { value: "4", label: "4.0 mm" },
              { value: "5", label: "5.0 mm" },
              { value: "auto", label: "Oto — en az delik" },
            ]}
            hint="Elindeki takımın adımını seç. Oto yalnızca sapmayı ölçebilir, dikişin sıklığı senin kararın."
            onChange={(v) =>
              setParams((p) => {
                if (v === "auto") {
                  const { pitch: _drop, ...rest } = p;
                  return rest;
                }
                return { ...p, pitch: Number(v) };
              })
            }
          />
          <Slider
            label="Dikiş payı"
            value={params.stitchMargin}
            min={2.5}
            max={5}
            step={0.5}
            unit="mm"
            onChange={(v) => set("stitchMargin", v)}
          />
          <Slider
            label="Köşe yarıçapı"
            value={params.cornerRadius}
            min={0}
            max={10}
            step={0.5}
            unit="mm"
            onChange={(v) => set("cornerRadius", v)}
          />
          <Choice<string>
            label="Kalem payı"
            value={String(params.penAllowance)}
            options={[
              { value: "0", label: "0" },
              { value: "0.3", label: "0.3mm" },
              { value: "0.5", label: "0.5mm" },
            ]}
            hint="Kalem ucu dışa kaçtığı için şablon o kadar küçük basılır."
            onChange={(v) => set("penAllowance", Number(v))}
          />
        </fieldset>

        <fieldset className="group" style={{ border: 0, margin: 0, padding: 0 }}>
          <legend>Baskı</legend>

          <Choice<string>
            label="Delikler"
            value={print.printAllHoles ? "all" : "anchors"}
            options={[
              { value: "anchors", label: "Sadece köşe" },
              { value: "all", label: "Hepsi" },
            ]}
            hint="Delikleri iron ile kendin yürüyorsan köşe çapaları yeterli; kapak sayfasında kenar başına sayı var."
            onChange={(v) =>
              setPrint((p) => ({ ...p, printAllHoles: v === "all" }))
            }
          />

          <div className="field">
            <div className="field-head">
              <label htmlFor="cal">Ölçtüğün kare</label>
              <span className="field-value">nominal 50mm</span>
            </div>
            <div className="calibrate">
              <input
                id="cal"
                type="number"
                step="0.1"
                min="1"
                value={print.measured}
                onChange={(e) =>
                  setPrint((p) => ({ ...p, measured: e.target.value }))
                }
              />
              <button
                type="button"
                onClick={() => {
                  void pdfModule().then(({ scaleFromMeasurement }) => {
                    const r = scaleFromMeasurement(Number(print.measured));
                    setPrint((p) => ({
                      ...p,
                      scaleFactor: r.ok ? r.factor : p.scaleFactor,
                      note: r.message,
                      noteOk: r.ok,
                    }));
                  });
                }}
              >
                Uygula
              </button>
            </div>
            <p className="hint">
              PDF'i bas, kapaktaki kareyi cetvelle ölç, çıkan değeri buraya
              gir. Ölçek düzeltilir.
            </p>
            {print.note !== "" && (
              <p className="hint" data-tone={print.noteOk ? "ok" : "bad"}>
                {print.note}
              </p>
            )}
          </div>

          <button
            type="button"
            className="primary"
            disabled={print.busy || !result.ok}
            onClick={() => {
              if (!result.ok) return;
              setPrint((p) => ({ ...p, busy: true }));
              pdfModule()
                .then(({ downloadPatternPdf }) =>
                  downloadPatternPdf(result.value, {
                    printAllHoles: print.printAllHoles,
                    scaleFactor: print.scaleFactor,
                    title: `Kartlık ${params.cardCount} yuva`,
                  }),
                )
                .catch((err: unknown) => {
                  setPrint((p) => ({
                    ...p,
                    note:
                      "PDF üretilemedi: " +
                      (err instanceof Error ? err.message : String(err)),
                    noteOk: false,
                  }));
                })
                .finally(() => setPrint((p) => ({ ...p, busy: false })));
            }}
          >
            {print.busy ? "Hazırlanıyor…" : "PDF indir"}
          </button>
          {print.scaleFactor !== 1 && (
            <p className="hint">
              Ölçek düzeltmesi aktif: ×{print.scaleFactor.toFixed(4)}
            </p>
          )}
        </fieldset>
      </aside>

      <main className="stage">
        {!result.ok ? (
          <ul className="diagnostics">
            <li className="diagnostic" data-severity="error">
              <code>ÇÖZÜLEMEDİ</code>
              <span>
                Bu parametrelerle kalıp üretilemiyor: {result.message}
                {" "}Dikiş payını küçültmeyi ya da yuva sayısını azaltmayı dene.
              </span>
            </li>
          </ul>
        ) : (
          <Result value={result.value} params={params} />
        )}
      </main>
    </div>
  );
}

function Result({
  value,
  params,
}: {
  value: ReturnType<typeof generateCardHolder>;
  params: CardHolderParams;
}) {
  const s = value.summary;
  const outer = value.pieces.find((p) => p.id === "outer");

  return (
    <>
      {value.diagnostics.length > 0 && (
        <ul className="diagnostics">
          {value.diagnostics.map((d, i) => (
            <li key={i} className="diagnostic" data-severity={d.severity}>
              <code>{d.code}</code>
              <span>{d.message}</span>
            </li>
          ))}
        </ul>
      )}

      <div className="stage-head">
        <h2>Parçalar</h2>
        <span className="scale-note">
          {params.cardCount} yuva · {params.construction === "t-slot" ? "T-slot" : "düz yığın"} ·{" "}
          {s.pitch}mm adım · {s.totalHoles} delik
        </span>
      </div>

      <div className="legend">
        <span>
          <i className="swatch" style={{ borderTopColor: "var(--bone)" }} /> kesim
        </span>
        <span>
          <i
            className="swatch"
            style={{ borderTopColor: "var(--brass-dim)", borderTopStyle: "dashed" }}
          />{" "}
          dikiş hattı
        </span>
        <span>
          <i
            className="swatch"
            style={{ borderTopColor: "var(--chalk)", borderTopStyle: "dotted" }}
          />{" "}
          kat
        </span>
        <span>
          <i className="swatch dot" /> delik
        </span>
      </div>

      {value.pieces.map((piece) => (
        <section className="piece" key={piece.id}>
          <div className="piece-head">
            <span className="piece-name">{piece.name}</span>
            <span className="piece-meta">
              ×{piece.quantity} · {piece.width.toFixed(1)} × {piece.height.toFixed(1)}mm ·{" "}
              {piece.leatherThickness.toFixed(1)}mm deri
            </span>
          </div>
          <PieceView piece={piece} pxPerMm={PX_PER_MM} />
        </section>
      ))}

      <div className="columns">
        <table className="readout">
          <caption>Kesit çözümü</caption>
          <tbody>
            {value.crossSection.layers.map((l) => (
              <tr key={l.layerId}>
                <th scope="row">{l.name}</th>
                <td className="num">{l.straightLength.toFixed(2)}</td>
                <td className="num">+{l.bendAllowance.toFixed(2)}</td>
                <td className="num">= {l.flatLength.toFixed(2)} mm</td>
              </tr>
            ))}
          </tbody>
        </table>

        <table className="readout">
          <caption>Ölçüler</caption>
          <tbody>
            <tr>
              <th scope="row">bölme genişliği</th>
              <td className="num">{s.compartmentWidth.toFixed(1)} mm</td>
            </tr>
            <tr>
              <th scope="row">yuva yığını</th>
              <td className="num">{s.slotStackHeight.toFixed(1)} mm</td>
            </tr>
            <tr>
              <th scope="row">kat payı</th>
              <td className="num">{s.foldAllowance.toFixed(2)} mm</td>
            </tr>
            <tr>
              <th scope="row">kapalı kalınlık</th>
              <td className="num">{s.closedThickness.toFixed(2)} mm</td>
            </tr>
            <tr>
              <th scope="row">kart yüklü</th>
              <td className="num">{s.loadedThickness.toFixed(2)} mm</td>
            </tr>
            <tr>
              <th scope="row">kenar kalınlığı</th>
              <td className="num">{s.edgeThickness.toFixed(2)} mm</td>
            </tr>
            <tr>
              <th scope="row">A4</th>
              <td className="num">{s.fitsA4 ? "sığıyor" : "bölünecek"}</td>
            </tr>
          </tbody>
        </table>

        {outer?.stitchPlan !== undefined && (
          <table className="readout">
            <caption>Dikiş planı — dış kabuk</caption>
            <tbody>
              {stitchSummaryFor(outer.stitchPlan).map((line, i) => (
                <tr key={i}>
                  <td colSpan={2}>{line}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>
    </>
  );
}
ODK_EOF_3

echo "==> apps/web/src/styles.css"
cat > apps/web/src/styles.css << 'ODK_EOF_4'
/*
  TASARIM NOTU
  ────────────────────────────────────────────────────────────────────
  Bu bir alet, tanıtım sayfası değil. Palet konunun kendi dünyasından:
  deri işçisinin gün boyu baktığı şey kesim matı. Koyu yeşil mat, üstünde
  bone beyazı kesim hatları, pirinç renginde dikiş delikleri.

  Mat ızgarası süs değil ÖLÇÜM ARACI: 10mm aralıklı, kalın çizgiler 50mm.
  Yani ekrandaki ızgara, kullanıcının masasındaki matın aynısı ve ölçek
  referansı olarak okunabiliyor.

  Tipografi: her sayı monospace (IBM Plex Mono) — ölçüler hizalanmalı ve
  rakamlar eşit genişlikte olmalı ki 93.4 ile 103.4 yan yana okunabilsin.
  Etiketler condensed sans, çünkü dar kontrol rayında yer dar.
*/

:root {
  --mat: #14312b;
  --mat-deep: #0e2420;
  --mat-grid: #1d443b;
  --mat-grid-major: #2a5f52;

  --panel: #0b1c19;
  --panel-edge: #1c3a34;

  --bone: #f2efe6;
  --bone-dim: #a8b5ae;
  --bone-faint: #6d8079;

  --brass: #e0a458;
  --brass-dim: #8a6535;
  --chalk: #6fb3a0;

  --warn: #d9973f;
  --error: #d9634f;

  /* JetBrains Mono: PDF katmanıyla aynı font. IBM Plex Mono
     @pdf-lib/fontkit ile boşluk karakterinde patlıyor (bkz.
     packages/print/src/print.test.ts), ekran ve baskı ayrışmasın diye
     ikisi de buna geçti. */
  --mono: "JetBrains Mono", ui-monospace, "SFMono-Regular", monospace;
  --sans: "IBM Plex Sans Condensed", system-ui, -apple-system, sans-serif;

  --rail: 320px;
}

* {
  box-sizing: border-box;
}

html,
body {
  margin: 0;
  padding: 0;
  background: var(--panel);
  color: var(--bone);
  font-family: var(--sans);
  -webkit-font-smoothing: antialiased;
}

body {
  min-height: 100vh;
}

/* ── Kabuk ─────────────────────────────────────────────────────────── */

.shell {
  display: grid;
  grid-template-columns: var(--rail) 1fr;
  min-height: 100vh;
}

.rail {
  background: var(--panel);
  border-right: 1px solid var(--panel-edge);
  padding: 20px 18px 40px;
  overflow-y: auto;
}

.stage {
  background: var(--mat-deep);
  padding: 20px 24px 60px;
  overflow-x: auto;
}

@media (max-width: 860px) {
  .shell {
    grid-template-columns: 1fr;
  }
  .rail {
    border-right: none;
    border-bottom: 1px solid var(--panel-edge);
  }
}

/* ── Başlık ────────────────────────────────────────────────────────── */

.masthead {
  margin-bottom: 26px;
}

.masthead h1 {
  font-size: 19px;
  font-weight: 700;
  letter-spacing: 0.02em;
  margin: 0 0 4px;
}

.masthead p {
  font-family: var(--mono);
  font-size: 11px;
  line-height: 1.5;
  color: var(--bone-faint);
  margin: 0;
}

/* ── Kontroller ────────────────────────────────────────────────────── */

.group {
  margin-bottom: 22px;
}

.group > legend,
.group-title {
  font-family: var(--mono);
  font-size: 10px;
  letter-spacing: 0.14em;
  text-transform: uppercase;
  color: var(--bone-faint);
  margin: 0 0 10px;
  padding: 0;
  display: block;
}

.field {
  margin-bottom: 14px;
}

.field-head {
  display: flex;
  justify-content: space-between;
  align-items: baseline;
  margin-bottom: 5px;
}

.field-head label {
  font-size: 13px;
  color: var(--bone-dim);
}

.field-value {
  font-family: var(--mono);
  font-size: 12px;
  color: var(--bone);
}

input[type="range"] {
  width: 100%;
  height: 20px;
  appearance: none;
  background: transparent;
  cursor: pointer;
}

input[type="range"]::-webkit-slider-runnable-track {
  height: 2px;
  background: var(--panel-edge);
}

input[type="range"]::-moz-range-track {
  height: 2px;
  background: var(--panel-edge);
}

input[type="range"]::-webkit-slider-thumb {
  appearance: none;
  width: 13px;
  height: 13px;
  margin-top: -5.5px;
  background: var(--brass);
  border: none;
  border-radius: 0;
  transform: rotate(45deg);
}

input[type="range"]::-moz-range-thumb {
  width: 13px;
  height: 13px;
  background: var(--brass);
  border: none;
  border-radius: 0;
}

input[type="range"]:focus-visible {
  outline: 2px solid var(--chalk);
  outline-offset: 4px;
}

.segmented {
  display: flex;
  gap: 1px;
  background: var(--panel-edge);
  border: 1px solid var(--panel-edge);
}

.segmented button {
  flex: 1;
  background: var(--panel);
  color: var(--bone-dim);
  border: none;
  padding: 7px 4px;
  font-family: var(--sans);
  font-size: 12px;
  cursor: pointer;
}

.segmented button[aria-pressed="true"] {
  background: var(--brass);
  color: var(--mat-deep);
  font-weight: 600;
}

.segmented button:focus-visible {
  outline: 2px solid var(--chalk);
  outline-offset: -2px;
}

.hint {
  font-family: var(--mono);
  font-size: 10px;
  line-height: 1.5;
  color: var(--bone-faint);
  margin: 5px 0 0;
}

/* ── Tanılama ──────────────────────────────────────────────────────── */

.diagnostics {
  margin: 0 0 20px;
  padding: 0;
  list-style: none;
}

.diagnostic {
  display: flex;
  gap: 9px;
  padding: 9px 11px;
  margin-bottom: 6px;
  font-size: 13px;
  line-height: 1.45;
  background: var(--panel);
  border-left: 2px solid var(--bone-faint);
}

.diagnostic[data-severity="warning"] {
  border-left-color: var(--warn);
}

.diagnostic[data-severity="error"] {
  border-left-color: var(--error);
}

.diagnostic code {
  font-family: var(--mono);
  font-size: 10px;
  letter-spacing: 0.06em;
  color: var(--bone-faint);
  white-space: nowrap;
  padding-top: 2px;
}

/* ── Sahne ─────────────────────────────────────────────────────────── */

.stage-head {
  display: flex;
  flex-wrap: wrap;
  gap: 8px 22px;
  align-items: baseline;
  margin-bottom: 16px;
}

.stage-head h2 {
  font-size: 15px;
  font-weight: 600;
  margin: 0;
  letter-spacing: 0.02em;
}

.scale-note {
  font-family: var(--mono);
  font-size: 11px;
  color: var(--bone-faint);
}

.piece {
  margin-bottom: 30px;
}

.piece-head {
  display: flex;
  flex-wrap: wrap;
  gap: 6px 16px;
  align-items: baseline;
  margin-bottom: 8px;
}

.piece-name {
  font-size: 14px;
  font-weight: 600;
}

.piece-meta {
  font-family: var(--mono);
  font-size: 11px;
  color: var(--bone-dim);
}

.piece-canvas {
  background: var(--mat);
  border: 1px solid var(--mat-grid-major);
  display: block;
  max-width: 100%;
  height: auto;
}

/* ── Tablolar ──────────────────────────────────────────────────────── */

.readout {
  border-collapse: collapse;
  font-family: var(--mono);
  font-size: 12px;
  margin-bottom: 26px;
  min-width: 260px;
}

.readout caption {
  font-size: 10px;
  letter-spacing: 0.14em;
  text-transform: uppercase;
  color: var(--bone-faint);
  text-align: left;
  padding-bottom: 8px;
}

.readout th,
.readout td {
  text-align: left;
  padding: 5px 22px 5px 0;
  border-bottom: 1px solid var(--panel-edge);
  font-weight: 400;
}

.readout th {
  color: var(--bone-faint);
}

.readout td {
  color: var(--bone);
  font-variant-numeric: tabular-nums;
}

.readout td.num {
  text-align: right;
  padding-right: 0;
}

.columns {
  display: flex;
  flex-wrap: wrap;
  gap: 0 48px;
}

/* ── Açıklama ──────────────────────────────────────────────────────── */

.legend {
  display: flex;
  flex-wrap: wrap;
  gap: 6px 20px;
  font-family: var(--mono);
  font-size: 11px;
  color: var(--bone-dim);
  margin-bottom: 18px;
}

.legend span {
  display: flex;
  align-items: center;
  gap: 7px;
}

.swatch {
  width: 20px;
  height: 0;
  border-top-width: 2px;
  border-top-style: solid;
}

.swatch.dot {
  width: 7px;
  height: 7px;
  border: none;
  border-radius: 50%;
  background: var(--brass);
}

@media (prefers-reduced-motion: reduce) {
  * {
    transition: none !important;
    animation: none !important;
  }
}

/* ── Baskı paneli ──────────────────────────────────────────────────── */

.calibrate {
  display: flex;
  gap: 6px;
}

.calibrate input {
  flex: 1;
  min-width: 0;
  background: var(--mat-deep);
  border: 1px solid var(--panel-edge);
  color: var(--bone);
  font-family: var(--mono);
  font-size: 13px;
  padding: 6px 8px;
}

.calibrate input:focus-visible,
.calibrate button:focus-visible,
button.primary:focus-visible {
  outline: 2px solid var(--chalk);
  outline-offset: 2px;
}

.calibrate button {
  background: var(--panel);
  border: 1px solid var(--panel-edge);
  color: var(--bone-dim);
  font-family: var(--sans);
  font-size: 12px;
  padding: 6px 12px;
  cursor: pointer;
}

.calibrate button:hover {
  border-color: var(--brass-dim);
  color: var(--bone);
}

button.primary {
  width: 100%;
  margin-top: 4px;
  background: var(--brass);
  color: var(--mat-deep);
  border: none;
  padding: 11px;
  font-family: var(--sans);
  font-size: 14px;
  font-weight: 600;
  letter-spacing: 0.02em;
  cursor: pointer;
}

button.primary:disabled {
  background: var(--panel-edge);
  color: var(--bone-faint);
  cursor: not-allowed;
}

.hint[data-tone="ok"] {
  color: var(--chalk);
}

.hint[data-tone="bad"] {
  color: var(--error);
}

.dropdown {
  width: 100%;
  background: var(--mat-deep);
  border: 1px solid var(--panel-edge);
  color: var(--bone);
  font-family: var(--mono);
  font-size: 13px;
  padding: 7px 8px;
  cursor: pointer;
}

.dropdown:focus-visible {
  outline: 2px solid var(--chalk);
  outline-offset: 2px;
}
ODK_EOF_4

echo "==> Testler"
pnpm test

echo "==> Typecheck"
pnpm typecheck

cat << 'ODK_DONE'

============================================================
DUZELTMELER UYGULANDI
============================================================

Ayni kalipta once/sonra:
  once:  2.7mm adim, 207 delik
  sonra: 3.85mm adim, 145 delik   (%30 daha az emek)

Git:
  git add -A
  git commit -m "Adim secimi: tolerans bandi + kullanici kontrolu

- selectPitch iki asamali: once en kucuk sapma, sonra 0.05mm bandin
  icindeki adaylardan EN BUYUGU. Ilk surum 559.2mm cevre icin 2.7mm
  seciyordu (207 delik) cunku 0.005mm daha az sapiyordu; tum adaylarin
  sapmasi zaten 0.01mm altindaydi, yani olculemez bir kazanc icin 62
  fazla delik.
- iron adimi artik CardHolderParams uzerinden kullanici kontrolu,
  varsayilan 3.85mm. Otomatik secim yalnizca sapmayi olcebilir;
  disisin sikligi estetik bir karar ve kullaniciya ait.
- tek segmentli kapali hatta ozet 'cevre' diyor, '1. kenar' demiyor
- 248 test geciyor"

  git push
  vercel --prod
ODK_DONE
