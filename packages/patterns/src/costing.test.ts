import { describe, it, expect } from "vitest";
import {
  DEFAULT_RATES,
  DEFAULT_TIME_MODEL,
  DEFAULT_WASTE_FACTOR,
  costNotes,
  estimateCost,
} from "./costing.js";
import { BIFOLD_DEFAULTS, generateBifold } from "./bifold.js";
import { TOTE_DEFAULTS, generateTote } from "./tote.js";

const wallet95 = generateBifold({
  ...BIFOLD_DEFAULTS,
  cardSlotsPerSide: 2,
  stitchMargin: 3,
  reveal: 12,
  targetClosedWidth: 95,
  targetClosedHeight: 75,
});

describe("alan hesabı", () => {
  const c = estimateCost(wallet95);

  it("net alan parçaların toplamı", () => {
    // Kaba kontrol: iki panel ~190×75 + yuvalar. 20–40 dm² arası saçma
    // olurdu; bir cüzdan 2–5 dm² mertebesinde.
    expect(c.netAreaDm2).toBeGreaterThan(1.5);
    expect(c.netAreaDm2).toBeLessThan(6);
  });

  it("brüt alan fire kadar fazla", () => {
    expect(c.grossAreaDm2).toBeCloseTo(c.netAreaDm2 * DEFAULT_WASTE_FACTOR, 9);
  });

  it("çanta cüzdandan çok daha fazla deri istiyor", () => {
    const bag = estimateCost(generateTote(TOTE_DEFAULTS));
    expect(bag.netAreaDm2).toBeGreaterThan(c.netAreaDm2 * 2.5);
  });
});

describe("süre modeli", () => {
  const c = estimateCost(wallet95);

  it("dikiş süresi DİKİLEN deliğe göre, parça toplamına göre değil", () => {
    // Aynı fiziksel delik her katmanda ayrı sayılırsa süre 2–3 katına
    // çıkıyor; iplik bütün katmanlardan bir kerede geçiyor.
    expect(c.stitchingHours).toBeCloseTo(
      wallet95.summary.stitchedHoles / DEFAULT_TIME_MODEL.holesPerHour,
      9,
    );
    const perPieceSum = wallet95.pieces.reduce(
      (a, p) => a + (p.stitchPlan?.totalHoles ?? 0) * p.quantity,
      0,
    );
    expect(perPieceSum).toBeGreaterThan(wallet95.summary.stitchedHoles * 2);
  });

  it("delme ayrı sayılıyor ve dikişten hızlı", () => {
    expect(c.punchingHours).toBeGreaterThan(0);
    expect(c.punchingHours).toBeLessThan(c.stitchingHours);
  });

  it("bifold dikiş süresi belgelenmiş 2–4 saat bandına yakın", () => {
    // Tek dayanağımız: 'bir bifold için 2–4 saat dikiş bekleyin'.
    // Modelin bu mertebeyi vermesi, katsayının tamamen uydurma
    // olmadığının tek göstergesi.
    const full = estimateCost(generateBifold(BIFOLD_DEFAULTS));
    expect(full.stitchingHours).toBeGreaterThan(1);
    expect(full.stitchingHours).toBeLessThan(6);
  });

  it("toplam süre bileşenlerin toplamı", () => {
    expect(c.totalHours).toBeCloseTo(
      c.cuttingHours + c.punchingHours + c.stitchingHours + c.edgeHours + c.assemblyHours,
      9,
    );
  });

  it("delik başına adım artınca dikiş süresi düşüyor", () => {
    const fine = estimateCost(
      generateBifold({ ...BIFOLD_DEFAULTS, pitch: 3 }),
    );
    const coarse = estimateCost(
      generateBifold({ ...BIFOLD_DEFAULTS, pitch: 5 }),
    );
    expect(coarse.stitchingHours).toBeLessThan(fine.stitchingHours);
  });
});

describe("fiyat zinciri", () => {
  const c = estimateCost(wallet95);

  it("doğrudan maliyet bileşenlerin toplamı", () => {
    expect(c.directCost).toBeCloseTo(
      c.leatherCost + c.labourCost + c.consumablesCost + c.hardwareCost,
      6,
    );
  });

  it("genel gider ve marj sırayla uygulanıyor", () => {
    expect(c.overhead).toBeCloseTo(c.directCost * DEFAULT_RATES.overheadRate, 6);
    expect(c.totalCost).toBeCloseTo(c.directCost + c.overhead, 6);
    expect(c.margin).toBeCloseTo(c.totalCost * DEFAULT_RATES.marginRate, 6);
    expect(c.priceExVat).toBeCloseTo(c.totalCost + c.margin, 6);
  });

  it("KDV fiyatın üstüne biniyor", () => {
    expect(c.priceIncVat).toBeCloseTo(c.priceExVat * (1 + DEFAULT_RATES.vatRate), 6);
  });

  it("KDV sıfırsa fiyat değişmiyor", () => {
    const noVat = estimateCost(wallet95, { ...DEFAULT_RATES, vatRate: 0 });
    expect(noVat.priceIncVat).toBeCloseTo(noVat.priceExVat, 9);
  });

  it("deri fiyatı iki katına çıkınca satış fiyatı artıyor ama iki katına çıkmıyor", () => {
    // İşçilik payı büyük olduğu için deri fiyatı fiyatı doğrusal sürüklemez.
    const base = estimateCost(wallet95);
    const pricey = estimateCost(wallet95, {
      ...DEFAULT_RATES,
      leatherPerDm2: DEFAULT_RATES.leatherPerDm2 * 2,
    });
    expect(pricey.priceExVat).toBeGreaterThan(base.priceExVat);
    expect(pricey.priceExVat).toBeLessThan(base.priceExVat * 2);
  });

  it("paylar toplamda %100'ü geçmiyor", () => {
    expect(c.leatherShare + c.labourShare).toBeLessThanOrEqual(1);
  });
});

describe("uyarı notları", () => {
  it("fiyatların kullanıcıdan geldiğini her zaman söylüyor", () => {
    const notes = costNotes(estimateCost(wallet95));
    expect(notes.some((n) => n.message.includes("senin girdiğin"))).toBe(true);
  });

  it("dikiş katsayısının geçici olduğunu söylüyor", () => {
    const notes = costNotes(estimateCost(wallet95));
    expect(notes.some((n) => n.message.includes("GEÇİCİ"))).toBe(true);
  });

  it("işçilik payı yüksekse bunu belirtiyor", () => {
    const notes = costNotes(
      estimateCost(wallet95, { ...DEFAULT_RATES, leatherPerDm2: 1 }),
    );
    expect(notes.some((n) => n.message.includes("işçilik"))).toBe(true);
  });
});
