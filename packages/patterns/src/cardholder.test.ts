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
    // Kat DİKEY olduğu için düz uzunluk artık GENİŞLİK.
    const solved = layerResult(r.crossSection, "outer");
    expect(solved?.flatLength).toBeGreaterThan(0);
    // Kalem payı 0.3mm iki kenardan düşülmüş. Hassasiyet 3 = EPS;
    // Clipper'ın mikron ızgarasından ~60 nanometre artık kalıyor.
    expect(r.summary.outerFlatWidth).toBeCloseTo(
      (solved?.flatLength as number) - 0.6,
      3,
    );
  });

  it("dikiş adımı fiziksel iron listesinden", () => {
    expect([2.7, 3.0, 3.38, 3.85, 4.0, 5.0]).toContain(r.summary.pitch);
  });

  it("A4'e sığıyor — döndürülerek", () => {
    // Açık kartlık 222.9 × 96.4mm: düz hâlde A4'e sığmaz, 90° çevrilince
    // sığar. Kontrol döndürmeyi hesaba katıyor.
    expect(r.summary.fitsA4).toBe(true);
    expect(r.summary.outerFlatWidth).toBeGreaterThan(A4.width - 20);
    expect(r.summary.outerFlatHeight).toBeLessThan(A4.width - 20);
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
  it("yuva sayısı arttıkça dış kabuk hem uzuyor hem yükseliyor", () => {
    const a = generateCardHolder({ ...DEFAULT_PARAMS, cardCount: 3 });
    const b = generateCardHolder({ ...DEFAULT_PARAMS, cardCount: 6 });
    // Yükseklik kademeden, genişlik kalınlaşan kıvrımdan büyüyor.
    expect(b.summary.outerFlatHeight).toBeGreaterThan(a.summary.outerFlatHeight);
    expect(b.summary.outerFlatWidth).toBeGreaterThan(a.summary.outerFlatWidth);
  });

  it("deri kalınlaştıkça kat payı büyüyor", () => {
    const thin = generateCardHolder({ ...DEFAULT_PARAMS, slotThickness: 0.6 });
    const thick = generateCardHolder({ ...DEFAULT_PARAMS, slotThickness: 0.8 });
    expect(thick.summary.foldAllowance).toBeGreaterThan(thin.summary.foldAllowance);
  });

  it("kat payı kıvrım bölgesinin genişliği", () => {
    // Dış kabuğun düz uzunluğunun iki panelden fazlası.
    //
    // "dış − iç" almak BURADA YANLIŞ: yuva katmanı yalnızca ön panelden
    // geçiyor, dış kabuk ikisinden de. Farkı almak bir panel boyunu da
    // içine katıyor ve 121mm gibi saçma bir sayı üretiyordu.
    const r = generateCardHolder(DEFAULT_PARAMS);
    const outer = layerResult(r.crossSection, "outer")?.flatLength as number;
    expect(r.summary.foldAllowance).toBeCloseTo(
      outer - 2 * r.summary.compartmentWidth,
      6,
    );
    // Kart yığını kalınlaştıkça kıvrım bölgesi genişler.
    const thicker = generateCardHolder({ ...DEFAULT_PARAMS, cardCount: 6 });
    expect(thicker.summary.foldAllowance).toBeGreaterThan(
      r.summary.foldAllowance,
    );
  });

  it("kat DİKEY: kat çizgileri düşey", () => {
    const r = generateCardHolder(DEFAULT_PARAMS);
    const outer = r.pieces.find((p) => p.id === "outer");
    for (const f of outer?.foldLines ?? []) {
      expect(f.from.x).toBeCloseTo(f.to.x, 9);
      expect(f.from.y).not.toBeCloseTo(f.to.y, 3);
    }
  });

  it("ÜST KENAR AÇIK: kart ağzı dikilmiyor", () => {
    const r = generateCardHolder(DEFAULT_PARAMS);
    const outer = r.pieces.find((p) => p.id === "outer");
    expect(outer?.stitchLineClosed).toBe(false);
  });

  it("kalem payı kesim hattını küçültüyor", () => {
    const none = generateCardHolder({ ...DEFAULT_PARAMS, penAllowance: 0 });
    const some = generateCardHolder({ ...DEFAULT_PARAMS, penAllowance: 0.5 });
    expect(some.summary.outerFlatHeight).toBeCloseTo(
      none.summary.outerFlatHeight - 1,
      6,
    );
  });

  it("döndürülse bile sığmayan kalıp uyarı üretiyor", () => {
    const r = generateCardHolder({ ...DEFAULT_PARAMS, cardCount: 8, reveal: 22 });
    if (!r.summary.fitsA4) {
      expect(r.diagnostics.some((d) => d.code === "NEEDS_TILING")).toBe(true);
    } else {
      expect(r.diagnostics.some((d) => d.code === "NEEDS_TILING")).toBe(false);
    }
  });

  it("dikey yönde bölme daralıyor", () => {
    const h = generateCardHolder(DEFAULT_PARAMS);
    const v = generateCardHolder({ ...DEFAULT_PARAMS, orientation: "vertical" });
    expect(v.summary.compartmentWidth).toBeLessThan(h.summary.compartmentWidth);
  });
});
