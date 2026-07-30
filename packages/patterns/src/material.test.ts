import { describe, it, expect } from "vitest";
import {
  MM_PER_OZ,
  ozToMm,
  mmToOz,
  ozRangeToMm,
  leather,
  PROVISIONAL_K_FACTOR,
  RECOMMENDED_THICKNESS,
  BIFOLD_TARGET_CLOSED_THICKNESS,
  CARD_THICKNESS,
} from "./material.js";
import {
  DOCUMENTED_COMPARTMENT_WIDTH,
  CARD_SLIDING_CLEARANCE,
  PROVISIONAL_SLOT_REVEAL,
  MIN_SLOT_REVEAL,
  cardSlotGeometry,
  validateCardSlots,
  compartmentWidthDeviation,
} from "./cardslot.js";
import type { CardSlotSpec } from "./cardslot.js";

describe("ons -> milimetre", () => {
  it("1 oz = 1/64 inç = 0.396875mm (tam)", () => {
    expect(MM_PER_OZ).toBeCloseTo(0.396875, 9);
    expect(MM_PER_OZ).toBe(25.4 / 64);
  });

  it("belgelenmiş dönüşüm tablosuyla uyuşuyor", () => {
    // Sektör tabloları: 1 oz ≈ 0.4mm, 4 oz ≈ 1.6mm, 8 oz ≈ 3.2mm
    // Tablolar 0.1mm'ye yuvarlıyor; tam değer 4 oz'da 1.5875, 8 oz'da
    // 3.175. Karşılaştırma bu yuvarlama payıyla yapılmalı.
    expect(ozToMm(1)).toBeCloseTo(0.4, 2);
    expect(ozToMm(4)).toBeCloseTo(1.6, 1);
    expect(ozToMm(8)).toBeCloseTo(3.2, 1);
  });

  it("yuvarlama hatası 8 oz'da birikiyor — tam değer kullanmanın sebebi", () => {
    const rounded = 8 * 0.4;
    const exact = ozToMm(8);
    expect(Math.abs(rounded - exact)).toBeCloseTo(0.025, 3);
  });

  it("gidiş-dönüş kayıpsız", () => {
    for (const oz of [1, 2.5, 3, 4.5, 12]) {
      expect(mmToOz(ozToMm(oz))).toBeCloseTo(oz, 9);
    }
  });

  it("aralık ortalaması: 3/4 oz -> 1.39mm", () => {
    expect(ozRangeToMm(3, 4)).toBeCloseTo(1.389, 3);
  });
});

describe("k-faktörü varsayılanları", () => {
  it("hepsi sac metal literatürünün 0.33–0.50 bandında", () => {
    // Deri için ölçülmüş veri olmadığı için değerler bu banttan
    // seçildi. Bandın dışına çıkmak, dayanağı olmayan bir iddia olur.
    for (const k of Object.values(PROVISIONAL_K_FACTOR)) {
      expect(k).toBeGreaterThanOrEqual(0.33);
      expect(k).toBeLessThanOrEqual(0.5);
    }
  });

  it("sert deri yumuşaktan daha büyük k alıyor", () => {
    expect(PROVISIONAL_K_FACTOR["veg-tan-firm"]).toBeGreaterThan(
      PROVISIONAL_K_FACTOR["chrome-soft"],
    );
  });

  it("leather() sertliğe göre k atıyor", () => {
    expect(leather("veg-tan-firm", 1.2).kFactor).toBe(0.45);
    expect(leather("chrome-soft", 1.2).kFactor).toBe(0.38);
  });
});

describe("kalınlık önerileri", () => {
  it("aralıklar tutarlı: min <= preferred <= max", () => {
    for (const r of Object.values(RECOMMENDED_THICKNESS)) {
      expect(r.min).toBeLessThanOrEqual(r.preferred);
      expect(r.preferred).toBeLessThanOrEqual(r.max);
    }
  });

  it("yuva derisi dış kabuktan ince öneriliyor", () => {
    expect(RECOMMENDED_THICKNESS.cardSlot.preferred).toBeLessThan(
      RECOMMENDED_THICKNESS.outerShell.preferred,
    );
  });

  it("önerilen kalınlıklarla asgari bifold hedef kalınlığın altında kalıyor", () => {
    // Dış + iç + tek yuva katmanı, artı bir kart.
    const minimal =
      RECOMMENDED_THICKNESS.outerShell.preferred +
      RECOMMENDED_THICKNESS.innerShell.preferred +
      RECOMMENDED_THICKNESS.cardSlot.preferred +
      CARD_THICKNESS;
    expect(minimal).toBeLessThan(BIFOLD_TARGET_CLOSED_THICKNESS);
  });
});

describe("kart yuvası — bölme genişliği", () => {
  it("hesabımız belgelenmiş değerlere yakın (sapma < 3mm)", () => {
    // Bu test modelin sektör pratiğinden kopmasını yakalar.
    expect(Math.abs(compartmentWidthDeviation("horizontal"))).toBeLessThan(3);
    expect(Math.abs(compartmentWidthDeviation("vertical"))).toBeLessThan(3);
  });

  it("yatay bölme ~100mm", () => {
    const geo = cardSlotGeometry({
      count: 3,
      construction: "t-slot",
      orientation: "horizontal",
      leatherThickness: 0.7,
    });
    expect(geo.compartmentWidth).toBeCloseTo(100, 6);
    expect(
      Math.abs(geo.compartmentWidth - DOCUMENTED_COMPARTMENT_WIDTH.horizontal),
    ).toBeLessThan(1);
  });

  it("dikey bölme ~70mm", () => {
    const geo = cardSlotGeometry({
      count: 3,
      construction: "t-slot",
      orientation: "vertical",
      leatherThickness: 0.7,
    });
    expect(
      Math.abs(geo.compartmentWidth - DOCUMENTED_COMPARTMENT_WIDTH.vertical),
    ).toBeLessThan(1);
  });

  it("boşluk sabiti yöne göre farklı ve belgelenmiş genişlikleri tam veriyor", () => {
    expect(85.6 + CARD_SLIDING_CLEARANCE.horizontal + 7).toBeCloseTo(100, 6);
    expect(53.98 + CARD_SLIDING_CLEARANCE.vertical + 7).toBeCloseTo(69.98, 6);
    expect(CARD_SLIDING_CLEARANCE.vertical).toBeGreaterThan(
      CARD_SLIDING_CLEARANCE.horizontal,
    );
  });
});

describe("kart yuvası — T-slot vs stacked", () => {
  const base: CardSlotSpec = {
    count: 6,
    construction: "stacked",
    orientation: "horizontal",
    leatherThickness: 0.7,
  };

  it("stacked: kenar kalınlığı yuva sayısıyla çarpan olarak büyüyor", () => {
    const geo = cardSlotGeometry(base);
    expect(geo.edgeThickness).toBeCloseTo(6 * 0.7, 9);
  });

  it("T-slot: kenar kalınlığı yuva sayısından BAĞIMSIZ", () => {
    // Belgelenmiş temel avantaj. Modelin bunu yansıtması, kural
    // motorunun doğru öneri vermesinin ön koşulu.
    for (const count of [2, 4, 6, 8]) {
      const geo = cardSlotGeometry({ ...base, count, construction: "t-slot" });
      expect(geo.edgeThickness).toBeCloseTo(0.7, 9);
    }
  });

  it("T-slot 6 yuvada kenarda 3.5mm kazandırıyor", () => {
    const stacked = cardSlotGeometry(base);
    const tslot = cardSlotGeometry({ ...base, construction: "t-slot" });
    expect(stacked.edgeThickness - tslot.edgeThickness).toBeCloseTo(3.5, 9);
  });

  it("merkez bölge her iki yapımda da yığılıyor", () => {
    const stacked = cardSlotGeometry(base);
    const tslot = cardSlotGeometry({ ...base, construction: "t-slot" });
    expect(tslot.centerThickness).toBeCloseTo(stacked.centerThickness, 9);
  });

  it("parça dağılımı: en alt yuva düz dikdörtgen kalıyor", () => {
    const geo = cardSlotGeometry({ ...base, construction: "t-slot" });
    expect(geo.tSlotPieces).toBe(5);
    expect(geo.rectanglePieces).toBe(1);
    expect(geo.tSlotPieces + geo.rectanglePieces).toBe(6);
  });

  it("stacked'da hiç T-slot parçası yok", () => {
    const geo = cardSlotGeometry(base);
    expect(geo.tSlotPieces).toBe(0);
    expect(geo.rectanglePieces).toBe(6);
  });
});

describe("kart yuvası — yığın yüksekliği", () => {
  it("tek yuva tam kart yüksekliği", () => {
    const geo = cardSlotGeometry({
      count: 1,
      construction: "t-slot",
      orientation: "horizontal",
      leatherThickness: 0.7,
    });
    expect(geo.stackHeight).toBeCloseTo(53.98, 9);
  });

  it("5 yuva = kart yüksekliği + 4 kademe", () => {
    const geo = cardSlotGeometry({
      count: 5,
      construction: "t-slot",
      orientation: "horizontal",
      leatherThickness: 0.7,
      reveal: 12,
    });
    expect(geo.stackHeight).toBeCloseTo(53.98 + 4 * 12, 9);
  });

  it("sıfır yuva sıfır yükseklik", () => {
    const geo = cardSlotGeometry({
      count: 0,
      construction: "t-slot",
      orientation: "horizontal",
      leatherThickness: 0.7,
    });
    expect(geo.stackHeight).toBe(0);
  });

  it("kartlar takılıyken kalınlık artıyor", () => {
    const geo = cardSlotGeometry({
      count: 4,
      construction: "t-slot",
      orientation: "horizontal",
      leatherThickness: 0.7,
    });
    expect(geo.loadedThickness - geo.centerThickness).toBeCloseTo(4 * 0.76, 9);
  });
});

describe("kart yuvası — kural denetimi", () => {
  it("kademe alt sınırın altındaysa hata", () => {
    const d = validateCardSlots({
      count: 4,
      construction: "t-slot",
      orientation: "horizontal",
      leatherThickness: 0.7,
      reveal: 3,
    });
    const found = d.find((x) => x.code === "REVEAL_TOO_SMALL");
    expect(found?.severity).toBe("error");
  });

  it("varsayılan kademe alt sınırın üstünde", () => {
    expect(PROVISIONAL_SLOT_REVEAL).toBeGreaterThan(MIN_SLOT_REVEAL);
  });

  it("3'ten fazla stacked yuva uyarı üretiyor ve T-slot öneriyor", () => {
    const d = validateCardSlots({
      count: 6,
      construction: "stacked",
      orientation: "horizontal",
      leatherThickness: 0.7,
    });
    const found = d.find((x) => x.code === "STACKED_TOO_MANY");
    expect(found).toBeDefined();
    expect(found?.message).toContain("T-slot");
  });

  it("aynı yuva sayısı T-slot ile uyarı üretmiyor", () => {
    const d = validateCardSlots({
      count: 6,
      construction: "t-slot",
      orientation: "horizontal",
      leatherThickness: 0.7,
    });
    expect(d.find((x) => x.code === "STACKED_TOO_MANY")).toBeUndefined();
  });

  it("kalın yuva derisi uyarı üretiyor", () => {
    const d = validateCardSlots({
      count: 3,
      construction: "t-slot",
      orientation: "horizontal",
      leatherThickness: 1.4,
    });
    expect(d.find((x) => x.code === "SLOT_LEATHER_THICK")).toBeDefined();
  });

  it("önerilen kalınlıkta uyarı yok", () => {
    const d = validateCardSlots({
      count: 3,
      construction: "t-slot",
      orientation: "horizontal",
      leatherThickness: RECOMMENDED_THICKNESS.cardSlot.preferred,
    });
    expect(d).toHaveLength(0);
  });

  it("sıfır yuva hata", () => {
    const d = validateCardSlots({
      count: 0,
      construction: "t-slot",
      orientation: "horizontal",
      leatherThickness: 0.7,
    });
    expect(d.find((x) => x.code === "NO_SLOTS")?.severity).toBe("error");
  });
});
