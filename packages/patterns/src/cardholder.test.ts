import { describe, it, expect } from "vitest";
import { A4 } from "@odk/geometry";
import { DEFAULT_PARAMS, generateCardHolder } from "./cardholder.js";
import { foldLengthDelta, layerResult } from "./crosssection.js";

describe("generateCardHolder — varsayılan parametreler", () => {
  const r = generateCardHolder(DEFAULT_PARAMS);

  it("hata üretmiyor", () => {
    expect(r.diagnostics.filter((d) => d.severity === "error")).toHaveLength(0);
  });

  it("dış kabuk + T-slot + düz yuva parçaları üretiliyor", () => {
    expect(r.pieces.map((p) => p.id)).toEqual(["outer", "slot-rect", "slot-t"]);
  });

  it("4 yuva = 3 T-slot + 1 düz", () => {
    const t = r.pieces.find((p) => p.id === "slot-t");
    const rect = r.pieces.find((p) => p.id === "slot-rect");
    expect(t?.quantity).toBe(3);
    expect(rect?.quantity).toBe(1);
  });

  it("bölme genişliği belgelenmiş 100mm'ye yakın", () => {
    expect(r.summary.compartmentWidth).toBeCloseTo(100, 1);
  });

  it("dış kabukta çevre dikişi planı var, yuvalarda yok", () => {
    expect(r.pieces.find((p) => p.id === "outer")?.stitchPlan).toBeDefined();
    expect(r.pieces.find((p) => p.id === "slot-t")?.stitchPlan).toBeUndefined();
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
