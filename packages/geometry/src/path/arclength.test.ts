import { describe, it, expect } from "vitest";
import { vec, vecEq } from "../vec.js";
import { path, flattenPath } from "./path.js";
import {
  buildArcLengthTable,
  pointAtDistance,
  tangentAtDistance,
  findCorners,
  spansBetweenCorners,
} from "./arclength.js";

/** 100 x 50 dikdörtgen, CCW. Çevre 300. Köşeler 0 / 100 / 150 / 250'de. */
const rectPoly = flattenPath(
  path()
    .moveTo(vec(0, 0))
    .lineTo(vec(100, 0))
    .lineTo(vec(100, 50))
    .lineTo(vec(0, 50))
    .close(),
);
const table = buildArcLengthTable(rectPoly, true);

describe("buildArcLengthTable", () => {
  it("toplam uzunluk 300", () => {
    expect(table.totalLength).toBeCloseTo(300, 9);
  });

  it("kümülatif dizi kapanış kenarını içerir", () => {
    // 4 nokta + kapanış = 5 giriş
    expect(table.cumulative).toHaveLength(5);
    expect(table.cumulative[1]).toBeCloseTo(100, 9);
    expect(table.cumulative[2]).toBeCloseTo(150, 9);
    expect(table.cumulative[3]).toBeCloseTo(250, 9);
    expect(table.cumulative[4]).toBeCloseTo(300, 9);
  });
});

describe("pointAtDistance", () => {
  it("köşelere tam isabet", () => {
    expect(vecEq(pointAtDistance(table, 0), vec(0, 0))).toBe(true);
    expect(vecEq(pointAtDistance(table, 100), vec(100, 0))).toBe(true);
    expect(vecEq(pointAtDistance(table, 150), vec(100, 50))).toBe(true);
    expect(vecEq(pointAtDistance(table, 250), vec(0, 50))).toBe(true);
  });

  it("kenar ortalarını doğru bulur", () => {
    expect(vecEq(pointAtDistance(table, 50), vec(50, 0))).toBe(true);
    expect(vecEq(pointAtDistance(table, 125), vec(100, 25))).toBe(true);
    expect(vecEq(pointAtDistance(table, 200), vec(50, 50))).toBe(true);
    expect(vecEq(pointAtDistance(table, 275), vec(0, 25))).toBe(true);
  });

  it("kapalı yolda sarar", () => {
    expect(vecEq(pointAtDistance(table, 300), vec(0, 0))).toBe(true);
    expect(vecEq(pointAtDistance(table, 350), vec(50, 0))).toBe(true);
    expect(vecEq(pointAtDistance(table, -25), vec(0, 25))).toBe(true);
  });

  it("açık yolda kırpar", () => {
    const open = buildArcLengthTable(rectPoly, false);
    expect(vecEq(pointAtDistance(open, 1000), vec(0, 50))).toBe(true);
    expect(vecEq(pointAtDistance(open, -50), vec(0, 0))).toBe(true);
  });

  it("eşit aralıklı örnekleme eşit mesafe verir", () => {
    // Dikiş dağıtıcısının dayandığı temel özellik.
    const step = 3.85;
    let prev = pointAtDistance(table, 0);
    for (let d = step; d <= 90; d += step) {
      const cur = pointAtDistance(table, d);
      expect(Math.hypot(cur.x - prev.x, cur.y - prev.y)).toBeCloseTo(step, 6);
      prev = cur;
    }
  });
});

describe("tangentAtDistance", () => {
  it("alt kenarda +x, sağ kenarda +y", () => {
    expect(vecEq(tangentAtDistance(table, 50), vec(1, 0), 0.01)).toBe(true);
    expect(vecEq(tangentAtDistance(table, 125), vec(0, 1), 0.01)).toBe(true);
    expect(vecEq(tangentAtDistance(table, 200), vec(-1, 0), 0.01)).toBe(true);
  });
});

describe("findCorners", () => {
  it("dikdörtgende 4 köşe bulur", () => {
    const corners = findCorners(table);
    expect(corners).toHaveLength(4);
    expect(corners.map((c) => Math.round(c.distance))).toEqual([0, 100, 150, 250]);
  });

  it("köşe dönüşleri 90 derece, sola (pozitif)", () => {
    for (const c of findCorners(table)) {
      expect(c.turn).toBeCloseTo(Math.PI / 2, 6);
    }
  });

  it("düzleştirilmiş eğride yumuşak noktaları köşe saymaz", () => {
    // Yuvarlatılmış kenar: bezier'in ürettiği yüzlerce nokta köşe değil.
    const rounded = flattenPath(
      path()
        .moveTo(vec(0, 0))
        .lineTo(vec(40, 0))
        .cubicTo(vec(50, 0), vec(50, 10), vec(50, 20))
        .lineTo(vec(0, 20))
        .close(),
    );
    const t = buildArcLengthTable(rounded, true);
    const corners = findCorners(t, 25);
    // Sadece gerçek kırılmalar: sol alt, sol üst ve yuvarlatmanın iki ucu
    // (teğet sürekli olduğu için uçlar köşe sayılmaz) -> 2 veya 3 arası.
    expect(corners.length).toBeLessThanOrEqual(3);
    expect(corners.length).toBeGreaterThanOrEqual(2);
  });
});

describe("spansBetweenCorners", () => {
  it("dikdörtgeni 100/50/100/50 olarak böler", () => {
    const spans = spansBetweenCorners(table, findCorners(table));
    expect(spans.map((s) => Math.round(s.length))).toEqual([100, 50, 100, 50]);
  });

  it("span uzunlukları toplamı çevreye eşit", () => {
    const spans = spansBetweenCorners(table, findCorners(table));
    const total = spans.reduce((acc, s) => acc + s.length, 0);
    expect(total).toBeCloseTo(table.totalLength, 6);
  });

  it("köşe yoksa tek span döner", () => {
    const spans = spansBetweenCorners(table, []);
    expect(spans).toHaveLength(1);
    expect(spans[0]?.length).toBeCloseTo(300, 9);
  });
});
