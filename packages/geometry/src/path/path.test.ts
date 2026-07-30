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
