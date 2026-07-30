import { describe, it, expect } from "vitest";
import { inchToMm } from "@odk/geometry";
import { leather, ozToMm } from "./material.js";
import type { CrossSection, Layer } from "./crosssection.js";
import {
  foldLengthDelta,
  naturalInnerRadius,
  solveCrossSection,
  hasErrors,
  layerResult,
  degToRad,
} from "./crosssection.js";

function layer(id: string, thicknessMm: number): Layer {
  return {
    id,
    name: id,
    spec: leather("veg-tan-firm", thicknessMm),
  };
}

describe("foldLengthDelta — modelin çekirdek formülü", () => {
  it("180° katta fark π × aralık", () => {
    expect(foldLengthDelta(4, 180)).toBeCloseTo(Math.PI * 4, 9);
    expect(foldLengthDelta(1, 180)).toBeCloseTo(Math.PI, 9);
  });

  it("90° katta fark (π/2) × aralık", () => {
    expect(foldLengthDelta(4, 90)).toBeCloseTo((Math.PI / 2) * 4, 9);
  });

  it("aralık sıfırsa fark sıfır", () => {
    expect(foldLengthDelta(0, 180)).toBe(0);
  });

  it("BELGELENMİŞ KURALLA DOĞRULAMA: yarım inç kuralı", () => {
    // MAKESUPPLY bifold kuralı: dış kabuk iç kabuktan ~yarım inç uzun
    // olmalı (iç 8.5″ ise dış 9″). Yarım inç = 12.7mm.
    //
    // Model, 4mm'lik kapalı yığın kalınlığı için ne söylüyor?
    const halfInch = inchToMm(0.5);
    const modelSaysFor4mmStack = foldLengthDelta(4, 180);

    expect(halfInch).toBeCloseTo(12.7, 6);
    expect(modelSaysFor4mmStack).toBeCloseTo(12.566, 3);

    // Zanaatkârın deneyimle bulduğu sayı ile fiziğin verdiği sayı
    // 0.15mm içinde örtüşüyor. Bu, doğru terimi modellediğimizin
    // bağımsız kanıtı.
    expect(Math.abs(halfInch - modelSaysFor4mmStack)).toBeLessThan(0.15);
  });

  it("yarım inç kuralı hangi yığın kalınlığına karşılık geliyor", () => {
    // Tersten: 12.7mm fark hangi aralıktan gelir?
    const gap = inchToMm(0.5) / degToRad(180);
    expect(gap).toBeCloseTo(4.04, 2);
    // 4mm — belgelenmiş "iyi bifold 6–8mm kalınlık" hedefinin içinde,
    // yani kuralın çıktığı yığın makul bir bifold.
  });
});

describe("naturalInnerRadius", () => {
  it("sarılan yığının yarısı", () => {
    expect(naturalInnerRadius(8)).toBe(4);
    expect(naturalInnerRadius(0)).toBe(0);
  });
});

describe("solveCrossSection — basit bifold", () => {
  /**
   * İki katmanlı bifold kesiti:
   *   iç kabuk (0.8mm) ve dış kabuk (1.0mm)
   *   ortada 180° kat, sarılan yığın 4mm
   *   her iki yanda 95mm düz bölüm
   */
  const inner = layer("inner", 0.8);
  const outer = layer("outer", 1.0);

  const cs: CrossSection = {
    name: "bifold-2-katman",
    layers: [inner, outer],
    runs: [
      { id: "left", name: "sol panel", length: 95, layers: ["inner", "outer"] },
      { id: "right", name: "sağ panel", length: 95, layers: ["inner", "outer"] },
    ],
    folds: [
      {
        id: "spine",
        name: "sırt",
        angleDeg: 180,
        innerRadius: naturalInnerRadius(4),
        stack: ["inner", "outer"],
      },
    ],
  };

  const result = solveCrossSection(cs);

  it("hata üretmiyor", () => {
    expect(hasErrors(result)).toBe(false);
  });

  it("dış kabuk iç kabuktan uzun", () => {
    const i = layerResult(result, "inner");
    const o = layerResult(result, "outer");
    expect(o?.flatLength).toBeGreaterThan(i?.flatLength as number);
  });

  it("fark, aralarındaki mesafeden hesaplanan değere eşit", () => {
    const i = layerResult(result, "inner");
    const o = layerResult(result, "outer");
    const delta = (o?.flatLength as number) - (i?.flatLength as number);

    // Nötr eksenler arası mesafe:
    //   iç: r + 0.45*0.8 = 2 + 0.36 = 2.36
    //   dış: r + 0.8 + 0.45*1.0 = 2 + 0.8 + 0.45 = 3.25
    //   aralık = 0.89
    expect(delta).toBeCloseTo(foldLengthDelta(0.89, 180), 6);
  });

  it("düz bölümler her iki katmana da tam ekleniyor", () => {
    expect(layerResult(result, "inner")?.straightLength).toBeCloseTo(190, 9);
    expect(layerResult(result, "outer")?.straightLength).toBeCloseTo(190, 9);
  });

  it("düz uzunluk = düz bölüm + kıvrım payı", () => {
    for (const lr of result.layers) {
      expect(lr.flatLength).toBeCloseTo(lr.straightLength + lr.bendAllowance, 9);
    }
  });

  it("kıvrım sonucu yığın kalınlığını ve farkı raporluyor", () => {
    const f = result.folds[0];
    expect(f?.stackThickness).toBeCloseTo(1.8, 9);
    expect(f?.outerInnerDelta).toBeCloseTo(foldLengthDelta(0.89, 180), 6);
  });
});

describe("kıvrımda katman olmayan dolgu (gaps)", () => {
  const a = layer("a", 1.0);
  const b = layer("b", 1.0);

  function withGap(gap: number) {
    const cs: CrossSection = {
      name: "dolgu",
      layers: [a, b],
      runs: [{ id: "r", name: "r", length: 50, layers: ["a", "b"] }],
      folds: [
        {
          id: "f",
          name: "f",
          angleDeg: 180,
          innerRadius: 0.5,
          stack: ["a", "b"],
          gaps: { b: gap },
        },
      ],
    };
    return solveCrossSection(cs);
  }

  it("dolgu dış katmanı uzatıyor, iç katmanı etkilemiyor", () => {
    const none = withGap(0);
    const some = withGap(4);
    expect(layerResult(some, "a")?.flatLength).toBeCloseTo(
      layerResult(none, "a")?.flatLength as number,
      9,
    );
    expect(layerResult(some, "b")?.flatLength).toBeGreaterThan(
      layerResult(none, "b")?.flatLength as number,
    );
  });

  it("uzama tam olarak θ × dolgu kadar", () => {
    const delta =
      (layerResult(withGap(4), "b")?.flatLength as number) -
      (layerResult(withGap(0), "b")?.flatLength as number);
    expect(delta).toBeCloseTo(foldLengthDelta(4, 180), 9);
  });

  it("yığında olmayan katmana dolgu hata veriyor", () => {
    const r = solveCrossSection({
      name: "hatalı",
      layers: [a],
      runs: [{ id: "r", name: "r", length: 50, layers: ["a"] }],
      folds: [
        {
          id: "f",
          name: "f",
          angleDeg: 180,
          innerRadius: 0.5,
          stack: ["a"],
          gaps: { yok: 2 },
        },
      ],
    });
    expect(r.diagnostics.some((d) => d.code === "GAP_NOT_IN_STACK")).toBe(true);
  });

  it("negatif dolgu hata veriyor", () => {
    const r = withGap(-1);
    expect(r.diagnostics.some((d) => d.code === "NEGATIVE_GAP")).toBe(true);
  });
});

describe("k-faktörü ikincil terim — büyüklük kontrolü", () => {
  /**
   * Bu test bir davranışı değil, bir TASARIM İDDİASINI doğruluyor:
   * k'yı yanlış tahmin etmek kalıbı bozmaz, çünkü etkisi el kesim hata
   * payının altında. İddia yanlışsa k için ölçülmüş veri bulmak
   * zorunlu hale gelir.
   */
  function flatLengthWithK(k: number): number {
    const l: Layer = {
      id: "a",
      name: "a",
      spec: { temper: "veg-tan-firm", thickness: 1.2, kFactor: k },
    };
    const cs: CrossSection = {
      name: "tek katman",
      layers: [l],
      runs: [{ id: "r", name: "r", length: 100, layers: ["a"] }],
      folds: [
        { id: "f", name: "f", angleDeg: 180, innerRadius: 2, stack: ["a"] },
      ],
    };
    return layerResult(solveCrossSection(cs), "a")?.flatLength as number;
  }

  it("k 0.38 -> 0.45 arasındaki belirsizlik 0.5mm'nin altında etki yapıyor", () => {
    const diff = Math.abs(flatLengthWithK(0.45) - flatLengthWithK(0.38));
    expect(diff).toBeLessThan(0.5);
    expect(diff).toBeCloseTo(Math.PI * 1.2 * 0.07, 6);
  });

  it("buna karşılık katman ötelemesi 10 kat daha büyük etki yapıyor", () => {
    // 4mm yığında öteleme farkı ~12.6mm; k belirsizliği ~0.26mm.
    expect(foldLengthDelta(4, 180) / (Math.PI * 1.2 * 0.07)).toBeGreaterThan(10);
  });
});

describe("doğrulama", () => {
  const a = layer("a", 1.0);

  function csWith(overrides: Partial<CrossSection>): CrossSection {
    return {
      name: "test",
      layers: [a],
      runs: [{ id: "r", name: "r", length: 50, layers: ["a"] }],
      folds: [
        { id: "f", name: "f", angleDeg: 180, innerRadius: 2, stack: ["a"] },
      ],
      ...overrides,
    };
  }

  it("tanımsız katman atfını yakalar", () => {
    const r = solveCrossSection(
      csWith({ runs: [{ id: "r", name: "r", length: 50, layers: ["yok"] }] }),
    );
    expect(r.diagnostics.some((d) => d.code === "UNKNOWN_LAYER_REF")).toBe(true);
    expect(hasErrors(r)).toBe(true);
  });

  it("tekrarlanan katman id'sini yakalar", () => {
    const r = solveCrossSection(csWith({ layers: [a, layer("a", 2)] }));
    expect(r.diagnostics.some((d) => d.code === "DUPLICATE_LAYER_ID")).toBe(true);
  });

  it("geçersiz açıyı yakalar", () => {
    const r = solveCrossSection(
      csWith({
        folds: [
          { id: "f", name: "f", angleDeg: 0, innerRadius: 2, stack: ["a"] },
        ],
      }),
    );
    expect(r.diagnostics.some((d) => d.code === "BAD_ANGLE")).toBe(true);
  });

  it("aynı katmanın yığında iki kez geçmesini yakalar", () => {
    const r = solveCrossSection(
      csWith({
        folds: [
          {
            id: "f",
            name: "f",
            angleDeg: 180,
            innerRadius: 2,
            stack: ["a", "a"],
          },
        ],
      }),
    );
    expect(r.diagnostics.some((d) => d.code === "DUPLICATE_IN_STACK")).toBe(true);
  });

  it("sıfır kalınlığı yakalar", () => {
    const r = solveCrossSection(csWith({ layers: [layer("a", 0)] }));
    expect(r.diagnostics.some((d) => d.code === "ZERO_THICKNESS")).toBe(true);
  });

  it("k-faktörü aralık dışını yakalar", () => {
    const bad: Layer = {
      id: "a",
      name: "a",
      spec: { temper: "veg-tan-firm", thickness: 1, kFactor: 1.5 },
    };
    const r = solveCrossSection(csWith({ layers: [bad] }));
    expect(r.diagnostics.some((d) => d.code === "K_OUT_OF_RANGE")).toBe(true);
  });

  it("fiziksel olarak çok keskin yarıçapı uyarı olarak bildirir", () => {
    // Ölçüt EN İÇ KATMANIN kalınlığı: 4mm deri 0.1mm yarıçapla kıvrılamaz.
    const thick = layer("t", 4);
    const r = solveCrossSection({
      name: "keskin",
      layers: [thick],
      runs: [{ id: "r", name: "r", length: 50, layers: ["t"] }],
      folds: [
        { id: "f", name: "f", angleDeg: 180, innerRadius: 0.1, stack: ["t"] },
      ],
    });
    const d = r.diagnostics.find((x) => x.code === "TIGHT_RADIUS");
    expect(d).toBeDefined();
    expect(d?.severity).toBe("warning");
    // Uyarı, hesabı engellemez — kullanıcı bilinçli tercih yapabilir.
    expect(hasErrors(r)).toBe(false);
  });

  it("geçerli kesit hiç tanılama üretmez", () => {
    expect(solveCrossSection(csWith({}))).toMatchObject({ diagnostics: [] });
  });
});

describe("gerçek kalıp verisiyle akıl sağlığı kontrolü", () => {
  it("belgelenmiş billfold açık/kapalı ölçüleriyle tutarlı", () => {
    // planbleathercraft Billfold: açık 215mm, kapalı 108mm, kalınlık 15mm.
    // 108 × 2 = 216, açık ölçü 215 verilmiş.
    //
    // NOT: Bu tek başına kıvrım payını doğrulamaz çünkü verilen "açık"
    // ölçü bitmiş ürünün yayılmış hâli, kalıptaki düz uzunluk değil.
    // Yine de büyüklük mertebesi kontrolü: 15mm kapalı kalınlıkta dış
    // katman iç katmandan π×15 ≈ 47mm uzun olmalı ki bu 215mm'lik bir
    // parçada %22 — yani böyle bir cüzdanda kat payı ihmal edilemez.
    const delta = foldLengthDelta(15, 180);
    expect(delta).toBeCloseTo(47.1, 1);
    expect(delta / 215).toBeGreaterThan(0.2);
  });

  it("3 oz deri 1.19mm", () => {
    expect(ozToMm(3)).toBeCloseTo(1.19, 2);
  });
});
