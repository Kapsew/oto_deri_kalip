import { describe, it, expect } from "vitest";
import { vec } from "../vec.js";
import { path, flattenPath, signedArea, bbox } from "../path/path.js";
import { netArea } from "./clipper.js";
import {
  PEN_ALLOWANCES,
  DEFAULT_STITCH_MARGIN,
  cutLine,
  stitchLine,
  glueBand,
  narrowestWidth,
  bestPitchFit,
} from "./allowance.js";

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

describe("kalem payı", () => {
  it("seçenekler 0 / 0.3 / 0.5", () => {
    expect(PEN_ALLOWANCES).toEqual([0, 0.3, 0.5]);
  });

  it("pay 0 iken hat değişmez", () => {
    const nominal = rect(0, 0, 100, 50);
    expect(signedArea(cutLine(nominal, { penAllowance: 0 }))).toBeCloseTo(5000, 6);
  });

  it("0.3mm pay her kenardan içe alır: 99.4 x 49.4", () => {
    // Kalem ucu dışa kaçtığı için şablon KÜÇÜK basılır.
    const r = cutLine(rect(0, 0, 100, 50), { penAllowance: 0.3 });
    const b = bbox(r);
    expect(b.width).toBeCloseTo(99.4, 6);
    expect(b.height).toBeCloseTo(49.4, 6);
  });

  it("kerf yarısı kadar içe alır", () => {
    const r = cutLine(rect(0, 0, 100, 50), { kerf: 0.2 });
    expect(bbox(r).width).toBeCloseTo(99.8, 6);
  });

  it("kalem payı ve kerf toplanır", () => {
    const r = cutLine(rect(0, 0, 100, 50), { penAllowance: 0.3, kerf: 0.2 });
    expect(bbox(r).width).toBeCloseTo(99.2, 6);
  });
});

describe("dikiş hattı", () => {
  it("varsayılan pay 3.5mm", () => {
    expect(DEFAULT_STITCH_MARGIN).toBe(3.5);
  });

  it("kesim hattından 3.5mm içeride", () => {
    const s = stitchLine(rect(0, 0, 100, 50));
    const b = bbox(s);
    expect(b.width).toBeCloseTo(93, 1);
    expect(b.height).toBeCloseTo(43, 1);
  });

  it("dışbükey köşeler İÇE ötelemede keskin kalır", () => {
    // Beklenti düzeltildi. Yuvarlatma yalnızca DIŞA ötelemede dışbükey
    // köşelere uygulanır; içe ötelemede köşe doğal olarak keskin kalır ve
    // bu geometrik olarak doğrudur.
    //
    // SONUÇ: dikiş hattının köşesini yuvarlamak offset'in yan ürünü
    // olarak elde edilemez — ayrı ve bilinçli bir adım olmak zorunda
    // (Adım 7'de dikiş dağıtıcısıyla birlikte ele alınacak).
    const s = stitchLine(rect(0, 0, 100, 50));
    expect(s).toHaveLength(4);
  });

  it("pay parçadan büyükse hata atar", () => {
    expect(() => stitchLine(rect(0, 0, 100, 5), 3.5)).toThrow();
  });
});

describe("tutkal bandı", () => {
  it("örtüşmenin dış bandını verir, iç bölgeyi bırakır", () => {
    const a = rect(0, 0, 100, 50);
    const b = rect(0, 0, 100, 50);
    const band = glueBand(a, b, 3.5);
    // 5000 - (93 x 43 ≈ 3999) ≈ 1001, yuvarlatma nedeniyle biraz fazla
    expect(netArea(band)).toBeGreaterThan(950);
    expect(netArea(band)).toBeLessThan(1050);
  });

  it("örtüşme yoksa boş", () => {
    expect(glueBand(rect(0, 0, 10, 10), rect(50, 50, 10, 10))).toHaveLength(0);
  });

  it("örtüşme dikiş payından inceyse tamamı tutkal", () => {
    const a = rect(0, 0, 100, 50);
    const b = rect(0, 0, 100, 4); // 4mm şerit, 3.5mm pay sığmaz
    const band = glueBand(a, b, 3.5);
    expect(netArea(band)).toBeCloseTo(400, 0);
  });
});

describe("narrowestWidth", () => {
  it("dikdörtgende kısa kenarı bulur", () => {
    expect(narrowestWidth(rect(0, 0, 100, 20))).toBeCloseTo(20, 1);
    expect(narrowestWidth(rect(0, 0, 50, 12))).toBeCloseTo(12, 1);
  });

  it("kum saatinde dar boynu bulur (yok olma eşiğini değil)", () => {
    // Boyun genişliği 2mm (x=19..21). Parça boynundan koptuğunda iki
    // parçaya ayrılır ama toplam alan pozitif kalır; ölçüt bunu yakalamalı.
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
    const w = narrowestWidth(hourglass);
    expect(w).toBeGreaterThan(1);
    expect(w).toBeLessThan(4);
  });

  it("kural kontrolü: 8mm kenar payı kuralı geometriden doğrulanabilir", () => {
    // Kart yuvası ağzı ile kesim kenarı arasında en az 8mm olmalı.
    const okPart = rect(0, 0, 100, 30);
    const tooThin = rect(0, 0, 100, 6);
    expect(narrowestWidth(okPart)).toBeGreaterThan(8);
    expect(narrowestWidth(tooThin)).toBeLessThan(8);
  });
});

describe("bestPitchFit", () => {
  it("100mm kenarda 4.0mm adım tam oturur: 25 delik, sapma 0", () => {
    const fit = bestPitchFit(100);
    expect(fit).toBeDefined();
    expect(fit?.deviationPerHole).toBeCloseTo(0, 6);
    expect((fit?.pitch as number) * (fit?.holes as number)).toBeCloseTo(100, 6);
  });

  it("gerçek adım kenarı tam böler", () => {
    for (const len of [43, 67.5, 93, 110.4]) {
      const fit = bestPitchFit(len);
      expect(fit).toBeDefined();
      expect((fit?.actualPitch as number) * (fit?.holes as number)).toBeCloseTo(len, 6);
    }
  });

  it("sapma her zaman kabul edilebilir bandda (< 0.15mm)", () => {
    // Adım kümesi yeterince yoğun olduğu için her uzunlukta iyi bir
    // eşleşme bulunmalı. Bulunamazsa adım listesi yetersiz demektir.
    for (let len = 20; len <= 200; len += 0.5) {
      const fit = bestPitchFit(len);
      expect(fit?.deviationPerHole).toBeLessThan(0.15);
    }
  });

  it("adımdan kısa kenarda tanımsız döner", () => {
    expect(bestPitchFit(1, [3.85])).toBeUndefined();
  });
});
