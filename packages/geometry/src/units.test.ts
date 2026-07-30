import { describe, it, expect } from "vitest";
import {
  EPS,
  eq,
  lt,
  gt,
  isZero,
  snap,
  mmToPt,
  ptToMm,
  inchToMm,
  A4,
  CARD_ID1,
  IRON_PITCHES,
} from "./units.js";

describe("epsilon karşılaştırma", () => {
  it("float birikmesini eşit sayar", () => {
    // 0.1 + 0.2 === 0.30000000000000004 — çıplak === burada patlar.
    expect(eq(0.1 + 0.2, 0.3)).toBe(true);
    expect(0.1 + 0.2 === 0.3).toBe(false);
  });

  it("mikron altı farkı yok sayar, üstünü yakalar", () => {
    expect(eq(10, 10.0005)).toBe(true);
    expect(eq(10, 10.002)).toBe(false);
  });

  it("lt/gt tolerans bandında false döner", () => {
    expect(lt(10, 10.0005)).toBe(false);
    expect(gt(10.0005, 10)).toBe(false);
    expect(lt(10, 10.5)).toBe(true);
    expect(gt(10.5, 10)).toBe(true);
  });

  it("isZero negatif sıfırı da kabul eder", () => {
    expect(isZero(-0.0004)).toBe(true);
    expect(isZero(-0.01)).toBe(false);
  });

  it("EPS 1 mikron", () => {
    expect(EPS).toBe(0.001);
  });
});

describe("snap", () => {
  it("mikron hassasiyetine yuvarlar", () => {
    expect(snap(1.23456789)).toBe(1.235);
    expect(snap(0.1 + 0.2)).toBe(0.3);
  });
});

describe("baskı birimi dönüşümü", () => {
  it("1 inch = 25.4mm = 72pt", () => {
    expect(mmToPt(25.4)).toBeCloseTo(72, 9);
    expect(ptToMm(72)).toBeCloseTo(25.4, 9);
    expect(inchToMm(1)).toBe(25.4);
  });

  it("gidiş-dönüş kayıpsız", () => {
    for (const mm of [0.2, 3.85, 53.98, 210, 297]) {
      expect(ptToMm(mmToPt(mm))).toBeCloseTo(mm, 9);
    }
  });

  it("A4 point cinsinden 595.28 x 841.89", () => {
    // PDF üreticisinin beklediği değerler; sapma varsa ölçek bozulur.
    expect(mmToPt(A4.width)).toBeCloseTo(595.276, 3);
    expect(mmToPt(A4.height)).toBeCloseTo(841.89, 2);
  });
});

describe("sabitler", () => {
  it("ISO ID-1 kart ölçüleri", () => {
    expect(CARD_ID1.width).toBe(85.6);
    expect(CARD_ID1.height).toBe(53.98);
    expect(CARD_ID1.thickness).toBe(0.76);
  });

  it("iron adımları artan sırada", () => {
    const sorted = [...IRON_PITCHES].sort((a, b) => a - b);
    expect(IRON_PITCHES).toEqual(sorted);
  });
});
