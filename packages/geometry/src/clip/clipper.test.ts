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
