import { describe, it, expect } from "vitest";
import { vec, distance, vecEq } from "../vec.js";
import type { Cubic } from "./bezier.js";
import {
  cubicAt,
  cubicTangent,
  splitCubic,
  flattenCubic,
  isCubicFlat,
  cubicApproxLength,
  cubicFromLine,
  FLATTEN_TOLERANCE,
} from "./bezier.js";

/**
 * Çeyrek daire yaklaşımı. r=10, kontrol noktası uzaklığı k*r,
 * k = 4/3 * (sqrt(2) - 1) = 0.5522847498.
 * Gerçek yay uzunluğu (pi/2)*10 = 15.70796...
 */
const K = (4 / 3) * (Math.SQRT2 - 1);
const R = 10;
const quarter: Cubic = {
  p0: vec(R, 0),
  c1: vec(R, K * R),
  c2: vec(K * R, R),
  p1: vec(0, R),
};

describe("cubicAt", () => {
  it("uç noktaları birebir verir", () => {
    expect(cubicAt(quarter, 0)).toEqual(quarter.p0);
    expect(cubicAt(quarter, 1)).toEqual(quarter.p1);
  });

  it("çeyrek daire yaklaşımı yarıçapı korur", () => {
    // Bu kübik gerçek daire değil; maksimum sapma ~0.027% r.
    for (const t of [0.1, 0.25, 0.5, 0.75, 0.9]) {
      const p = cubicAt(quarter, t);
      expect(Math.hypot(p.x, p.y)).toBeCloseTo(R, 1);
    }
  });
});

describe("cubicTangent", () => {
  it("çeyrek daire başında teğet +y yönünde", () => {
    expect(vecEq(cubicTangent(quarter, 0), vec(0, 1))).toBe(true);
  });

  it("çeyrek daire sonunda teğet -x yönünde", () => {
    expect(vecEq(cubicTangent(quarter, 1), vec(-1, 0))).toBe(true);
  });
});

describe("splitCubic", () => {
  it("iki parça birleşim noktasında buluşur", () => {
    const [l, r] = splitCubic(quarter, 0.5);
    expect(vecEq(l.p1, r.p0)).toBe(true);
    expect(vecEq(l.p1, cubicAt(quarter, 0.5))).toBe(true);
  });

  it("parçaların uçları orijinali korur", () => {
    const [l, r] = splitCubic(quarter, 0.3);
    expect(l.p0).toEqual(quarter.p0);
    expect(r.p1).toEqual(quarter.p1);
  });
});

describe("cubicApproxLength", () => {
  it("çeyrek daire uzunluğu (pi/2)*r — bağıl hata < %0.02", () => {
    // Kübik bezier gerçek daire DEĞİLDİR. k=4/3*(sqrt2-1) yaklaşımının
    // uzunluk hatası ~%0.014 (r=10 için ~0.0022mm). Bu bir bug değil,
    // yöntemin sınırı. Kalıp ölçeğinde (mm) ihmal edilebilir, ama
    // testin bunu mutlak toleransla değil bağıl hatayla ölçmesi gerekir.
    const expected = (Math.PI / 2) * R; // 15.70796
    const actual = cubicApproxLength(quarter, 512);
    expect(Math.abs(actual - expected) / expected).toBeLessThan(0.0002);
  });

  it("düz çizgide tam uzunluk", () => {
    const line = cubicFromLine(vec(0, 0), vec(30, 40));
    expect(cubicApproxLength(line, 8)).toBeCloseTo(50, 9);
  });
});

describe("flattenCubic", () => {
  it("p0'ı dahil etmez, p1 ile biter", () => {
    const pts = flattenCubic(quarter);
    expect(vecEq(pts[0] as ReturnType<typeof vec>, quarter.p0)).toBe(false);
    expect(pts.at(-1)).toEqual(quarter.p1);
  });

  it("düz kübik tek noktaya iner", () => {
    const line = cubicFromLine(vec(0, 0), vec(100, 0));
    expect(isCubicFlat(line)).toBe(true);
    expect(flattenCubic(line)).toEqual([vec(100, 0)]);
  });

  it("tolerans içinde kalır: kirişlerden sapma <= tolerans", () => {
    const pts = [quarter.p0, ...flattenCubic(quarter, FLATTEN_TOLERANCE)];
    // Her kirişin orta noktası gerçek eğriye tolerans kadar yakın olmalı.
    // Yarıçap testi ile kontrol ediyoruz: kirişin orta noktası daireden
    // sagitta kadar sapar, bu da toleransı aşmamalı.
    for (let i = 1; i < pts.length; i++) {
      const a = pts[i - 1] as ReturnType<typeof vec>;
      const b = pts[i] as ReturnType<typeof vec>;
      const mid = { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 };
      const sagitta = R - Math.hypot(mid.x, mid.y);
      expect(sagitta).toBeLessThanOrEqual(FLATTEN_TOLERANCE + 0.01);
    }
  });

  it("düzleştirilmiş uzunluk gerçek uzunluğa yakınsar", () => {
    const pts = [quarter.p0, ...flattenCubic(quarter, 0.01)];
    let len = 0;
    for (let i = 1; i < pts.length; i++) {
      len += distance(
        pts[i - 1] as ReturnType<typeof vec>,
        pts[i] as ReturnType<typeof vec>,
      );
    }
    expect(len).toBeCloseTo((Math.PI / 2) * R, 2);
  });

  it("daha sıkı tolerans daha çok nokta üretir", () => {
    const coarse = flattenCubic(quarter, 0.5).length;
    const fine = flattenCubic(quarter, 0.01).length;
    expect(fine).toBeGreaterThan(coarse);
  });
});
