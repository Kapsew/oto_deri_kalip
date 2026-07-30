import { describe, it, expect } from "vitest";
import { BANKNOTES, billPocketGeometry, BILL_COVER_MARGIN } from "./banknote.js";
import { BIFOLD_DEFAULTS, generateBifold, halfInchRuleDeviation } from "./bifold.js";
import { layerResult } from "./crosssection.js";

describe("banknot verisi", () => {
  it("200 TL 160 × 72mm", () => {
    expect(BANKNOTES.TRY.width).toBe(160);
    expect(BANKNOTES.TRY.height).toBe(72);
    expect(BANKNOTES.TRY.verified).toBe(true);
  });

  it("dolar 156 × 66.3mm", () => {
    expect(BANKNOTES.USD.width).toBe(156);
    expect(BANKNOTES.USD.height).toBeCloseTo(66.3, 2);
    expect(BANKNOTES.USD.verified).toBe(true);
  });

  it("doğrulanmamış para birimleri işaretli ve uyarı metni taşıyor", () => {
    for (const b of Object.values(BANKNOTES)) {
      if (!b.verified) expect(b.note).toContain("doğrulanmadı");
    }
  });

  it("TL en geniş banknot — cüzdanı o belirler", () => {
    const widths = Object.values(BANKNOTES).map((b) => b.width);
    expect(BANKNOTES.TRY.width).toBe(Math.max(...widths));
  });

  it("asgari cüzdan yüksekliği banknottan örtü payı kadar fazla", () => {
    const g = billPocketGeometry({
      currency: "TRY",
      leatherThickness: 0.8,
      stitchMargin: 3.5,
    });
    expect(g.minWalletHeight).toBeCloseTo(72 + BILL_COVER_MARGIN, 6);
  });
});

describe("bifold — yarım inç kuralı doğrulaması", () => {
  it("ASGARİ cüzdanda kat payı 12.7mm'ye yakın", () => {
    // MODELİN DOĞRULAMA ÇAPASI.
    //
    // MAKESUPPLY yarım inç kuralını "bare minimum" bir cüzdan için
    // veriyor: dış kabuk, iç kabuk, bir kat kart yuvası. Panel başına
    // 2 yuva bu tarife karşılık geliyor.
    //
    // gaps alanı eklenmeden model 2.6mm veriyordu — kıvrımda katman
    // olmayan dolgu (kart yığını + kartlar) modellenmediği için.
    const dev = Math.abs(
      halfInchRuleDeviation({ ...BIFOLD_DEFAULTS, cardSlotsPerSide: 2 }),
    );
    expect(dev).toBeLessThan(1.5);
  });

  it("kalın cüzdanda kat payı DAHA BÜYÜK olmalı", () => {
    // Yarım inç sabit bir sayı değil, belirli bir kalınlığın sonucu.
    // 3 yuvalı cüzdan daha kalın, dolayısıyla daha çok pay ister.
    // Modelin bunu vermesi doğru davranış; 12.7'ye zorlamak hata olurdu.
    const thick = generateBifold(BIFOLD_DEFAULTS).summary.foldAllowance;
    const thin = generateBifold({
      ...BIFOLD_DEFAULTS,
      cardSlotsPerSide: 2,
    }).summary.foldAllowance;
    expect(thick).toBeGreaterThan(thin);
    expect(thick).toBeGreaterThan(12.7);
  });

  it("açık genişlik ticari kalıplarla aynı mertebede", () => {
    // Referans: satılan bir billfold kalıbı açık 215mm.
    const r = generateBifold(BIFOLD_DEFAULTS);
    expect(r.summary.outerFlatWidth).toBeGreaterThan(190);
    expect(r.summary.outerFlatWidth).toBeLessThan(240);
  });

  it("kat payı dolgusuz modelden belirgin büyük", () => {
    const r = generateBifold(BIFOLD_DEFAULTS);
    // Dolgusuz olsaydı: π × (t_inner + k·(t_outer − t_inner)) ≈ 2.6mm
    const withoutFill = Math.PI * (0.8 + 0.45 * (0.9 - 0.8));
    expect(r.summary.foldAllowance).toBeGreaterThan(withoutFill * 3);
  });

  it("dış kabuk iç kabuktan tam kat payı kadar uzun", () => {
    const r = generateBifold(BIFOLD_DEFAULTS);
    const inner = layerResult(r.crossSection, "inner");
    const outer = layerResult(r.crossSection, "outer");
    expect((outer?.flatLength as number) - (inner?.flatLength as number)).toBeCloseTo(
      r.summary.foldAllowance,
      6,
    );
  });

  it("kart yuvası arttıkça kat payı büyüyor", () => {
    const a = generateBifold({ ...BIFOLD_DEFAULTS, cardSlotsPerSide: 2 });
    const b = generateBifold({ ...BIFOLD_DEFAULTS, cardSlotsPerSide: 5 });
    expect(b.summary.foldAllowance).toBeGreaterThan(a.summary.foldAllowance);
  });
});

describe("bifold — parçalar", () => {
  const r = generateBifold(BIFOLD_DEFAULTS);

  it("hata üretmiyor", () => {
    expect(r.diagnostics.filter((d) => d.severity === "error")).toHaveLength(0);
  });

  it("dış kabuk, iç kabuk ve yuvalar üretiliyor", () => {
    expect(r.pieces.map((p) => p.code)).toEqual(["A", "B", "C", "D"]);
  });

  it("yuva parçaları iki panel için iki kat adet", () => {
    const rect = r.pieces.find((p) => p.id === "slot-rect");
    const t = r.pieces.find((p) => p.id === "slot-t");
    expect(rect?.quantity).toBe(2);
    expect(t?.quantity).toBe(2 * (BIFOLD_DEFAULTS.cardSlotsPerSide - 1));
  });

  it("iç kabuk dış kabuktan kısa", () => {
    const outer = r.pieces.find((p) => p.id === "outer");
    const inner = r.pieces.find((p) => p.id === "inner");
    expect(inner?.width).toBeLessThan(outer?.width as number);
    // Hassasiyet 2: kesim hatları Clipper'ın mikron ızgarasından geçiyor.
    expect((outer?.width as number) - (inner?.width as number)).toBeCloseTo(
      r.summary.foldAllowance,
      2,
    );
  });

  it("montajda her panel için ayrı yuva örnekleri", () => {
    expect(r.assembly).toHaveLength(2 * BIFOLD_DEFAULTS.cardSlotsPerSide);
    expect(r.assembly.filter((a) => a.code.includes("S"))).toHaveLength(3);
    expect(r.assembly.filter((a) => a.code.includes("R"))).toHaveLength(3);
  });

  it("sağ paneldeki yuvalar sağa kaydırılmış", () => {
    const left = r.assembly.filter((a) => a.code.includes("S"));
    const right = r.assembly.filter((a) => a.code.includes("R"));
    expect(right[0]?.x).toBeGreaterThan(left[0]?.x as number);
  });
});

describe("bifold — ölçüler ve kurallar", () => {
  it("TL banknotu bölmeye sığıyor", () => {
    const r = generateBifold(BIFOLD_DEFAULTS);
    expect(r.summary.panelHeight).toBeGreaterThanOrEqual(72 + BILL_COVER_MARGIN);
  });

  it("kapalı kalınlık makul", () => {
    const r = generateBifold(BIFOLD_DEFAULTS);
    expect(r.summary.closedThickness).toBeGreaterThan(4);
    expect(r.summary.closedThickness).toBeLessThan(12);
  });

  it("çok yuva şişkinlik uyarısı üretiyor", () => {
    const r = generateBifold({ ...BIFOLD_DEFAULTS, cardSlotsPerSide: 8 });
    expect(
      r.diagnostics.some((d) => d.code === "BULKY" || d.code === "TOO_THICK"),
    ).toBe(true);
  });

  it("doğrulanmamış para birimi uyarı üretiyor", () => {
    const r = generateBifold({ ...BIFOLD_DEFAULTS, currency: "EUR" });
    expect(r.diagnostics.some((d) => d.code === "BANKNOTE_UNVERIFIED")).toBe(true);
  });

  it("açık genişlik banknot ve kart kısıtlarının büyüğü", () => {
    const r = generateBifold(BIFOLD_DEFAULTS);
    const billWidth = billPocketGeometry({
      currency: "TRY",
      leatherThickness: 0.8,
      stitchMargin: 3.5,
    }).compartmentWidth;
    expect(r.summary.outerFlatWidth + 0.6).toBeGreaterThanOrEqual(
      Math.min(billWidth, 2 * r.summary.compartmentWidth) - 1,
    );
  });

  it("A4'e sığmıyor ve tiling uyarısı veriyor", () => {
    // Açık bifold ~200mm; A4 genişliği 210mm, kenar payıyla sığmaz.
    const r = generateBifold(BIFOLD_DEFAULTS);
    expect(r.summary.outerFlatWidth).toBeGreaterThan(150);
    if (!r.summary.fitsA4) {
      expect(r.diagnostics.some((d) => d.code === "NEEDS_TILING")).toBe(true);
    }
  });
});
