import { describe, it, expect } from "vitest";
import {
  vec,
  add,
  sub,
  scale,
  dot,
  cross,
  length,
  distance,
  normalize,
  lerp,
  perpCCW,
  perpCW,
  rotate,
  vecEq,
  distanceToSegment,
  ORIGIN,
} from "./vec.js";

describe("temel işlemler", () => {
  it("3-4-5 üçgeni", () => {
    expect(length(vec(3, 4))).toBe(5);
    expect(distance(vec(1, 1), vec(4, 5))).toBe(5);
  });

  it("toplama / çıkarma / ölçekleme", () => {
    expect(add(vec(1, 2), vec(3, 4))).toEqual(vec(4, 6));
    expect(sub(vec(5, 5), vec(2, 3))).toEqual(vec(3, 2));
    expect(scale(vec(2, -3), 2.5)).toEqual(vec(5, -7.5));
  });

  it("dik vektörlerin skaler çarpımı sıfır", () => {
    expect(dot(vec(1, 0), vec(0, 1))).toBe(0);
  });

  it("cross işareti dönüş yönünü verir", () => {
    expect(cross(vec(1, 0), vec(0, 1))).toBeGreaterThan(0); // CCW
    expect(cross(vec(0, 1), vec(1, 0))).toBeLessThan(0); // CW
  });
});

describe("normalize", () => {
  it("birim uzunluk üretir", () => {
    expect(length(normalize(vec(3, 4)))).toBeCloseTo(1, 12);
  });

  it("sıfır vektörde patlamaz", () => {
    // Dejenere kenarlar (aynı noktanın tekrarı) kalıplarda oluyor;
    // NaN üretirse tüm zincir bozulur.
    expect(normalize(ORIGIN)).toEqual(ORIGIN);
    expect(Number.isNaN(normalize(ORIGIN).x)).toBe(false);
  });
});

describe("dikey vektörler", () => {
  // NOT: toEqual burada kullanılamaz. -0 !== +0 olarak raporlanır ve
  // negasyon içeren her işlem (perp, neg, rotate) bu tuzağa düşer.
  // Vektör karşılaştırması her zaman vecEq ile yapılır.
  it("perpCCW 90 derece sola çevirir", () => {
    expect(vecEq(perpCCW(vec(1, 0)), vec(0, 1))).toBe(true);
  });

  it("perpCW 90 derece sağa çevirir", () => {
    expect(vecEq(perpCW(vec(1, 0)), vec(0, -1))).toBe(true);
  });

  it("iki kez perp uygulamak yönü tersine çevirir", () => {
    expect(vecEq(perpCCW(perpCCW(vec(3, 4))), vec(-3, -4))).toBe(true);
  });
});

describe("rotate", () => {
  it("90 derece dönüş", () => {
    const r = rotate(vec(1, 0), Math.PI / 2);
    expect(vecEq(r, vec(0, 1))).toBe(true);
  });

  it("360 derece dönüş başa döner", () => {
    const r = rotate(vec(12.5, -7.25), Math.PI * 2);
    expect(vecEq(r, vec(12.5, -7.25))).toBe(true);
  });
});

describe("lerp", () => {
  it("uç noktalar ve orta", () => {
    const a = vec(0, 0);
    const b = vec(10, 20);
    expect(lerp(a, b, 0)).toEqual(a);
    expect(lerp(a, b, 1)).toEqual(b);
    expect(lerp(a, b, 0.5)).toEqual(vec(5, 10));
  });
});

describe("distanceToSegment", () => {
  const a = vec(0, 0);
  const b = vec(10, 0);

  it("dik izdüşüm parça içinde", () => {
    expect(distanceToSegment(vec(5, 3), a, b)).toBeCloseTo(3, 12);
  });

  it("izdüşüm parça dışındaysa uç noktaya mesafe", () => {
    expect(distanceToSegment(vec(-4, 3), a, b)).toBeCloseTo(5, 12);
    expect(distanceToSegment(vec(14, 3), a, b)).toBeCloseTo(5, 12);
  });

  it("dejenere parçada uç noktaya mesafe", () => {
    expect(distanceToSegment(vec(3, 4), a, a)).toBeCloseTo(5, 12);
  });
});
