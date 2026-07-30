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
