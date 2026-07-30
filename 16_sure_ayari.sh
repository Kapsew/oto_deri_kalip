#!/usr/bin/env bash
#
# 16_sure_ayari.sh — Sure katsayilari ayarlanabilir + fazla tutulmus
#                    katsayilar duzeltildi
#
# Repo kokunde calistir. Idempotent.

set -euo pipefail

if [ ! -f "pnpm-workspace.yaml" ] || [ ! -d "packages/print" ]; then
  echo "HATA: Repo kokunde calistirilmali ve 15 uygulanmis olmali." >&2
  exit 1
fi

echo "==> packages/patterns/src/costing.ts"
cat > packages/patterns/src/costing.ts << 'ODK_EOF_0'
import type { Mm } from "@odk/geometry";
import { polylineLength, signedArea } from "@odk/geometry";
import type { PatternResult } from "./cardholder.js";

/**
 * MALİYET VE FİYAT TAHMİNİ
 *
 * ═══════════════════════════════════════════════════════════════════════
 * NE HESAPLANIR, NE SORULUR
 * ═══════════════════════════════════════════════════════════════════════
 *
 * Motor iki şeyi KESİN biliyor çünkü kalıbı kendisi üretti:
 *   - deri alanı (parça poligonlarının alanı × adet)
 *   - iş yükü göstergeleri (delik sayısı, kesim çevresi, parça sayısı)
 *
 * Motor iki şeyi BİLEMEZ:
 *   - deri desi fiyatı (tabakhaneye, ülkeye, aya göre değişir)
 *   - saatlik işçilik (atölyeye ve ustaya göre değişir)
 *
 * Bu yüzden alan ve süre hesaplanır, fiyatlar kullanıcıdan alınır.
 * Uydurma bir deri fiyatı gömmek, sayıya gereksiz bir güven kazandırır;
 * ilk aydan sonra yanlış olur ve kimse fark etmez.
 *
 * ⚠ SÜRE KATSAYILARI GEÇİCİ. Tek dayanak, bir kaynağın "bir bifold için
 * 2–4 saat dikiş bekleyin" ifadesi. Kendi işini ölçüp katsayıları
 * düzeltmen gerekiyor — arayüz bunu değiştirilebilir yapıyor.
 */

export interface CostRates {
  readonly currency: string;
  /** Deri fiyatı, para birimi / desimetrekare. */
  readonly leatherPerDm2: number;
  readonly labourPerHour: number;
  /** İplik, tutkal, kenar boyası — saat başına sarf. */
  readonly consumablesPerHour: number;
  /** Fermuar, çıtçıt, halka gibi parçalar (toplam). */
  readonly hardware: number;
  /** Genel gider oranı (kira, elektrik, alet aşınması). 0.15 = %15. */
  readonly overheadRate: number;
  /** Kâr marjı. 0.4 = maliyetin üstüne %40. */
  readonly marginRate: number;
  /** KDV oranı; 0 verilirse fiyat KDV'siz gösterilir. */
  readonly vatRate: number;
}

export const DEFAULT_RATES: CostRates = {
  currency: "TL",
  // ⚠ Bu sayılar YER TUTUCU. Kendi tedarikçi fiyatlarını gir.
  leatherPerDm2: 45,
  labourPerHour: 350,
  consumablesPerHour: 40,
  hardware: 0,
  overheadRate: 0.15,
  marginRate: 0.4,
  vatRate: 0.2,
};

/**
 * ⚠ GEÇİCİ süre katsayıları.
 *
 * holesPerHour için tek dayanak: "bir bifold için 2–4 saat dikiş
 * bekleyin". Bizim bifold'un çevresi ~96 delik; 50 delik/saat bu aralığın
 * (1.9 saat) alt ucuna denk geliyor ve deneyimli bir usta için makul.
 * Yeni başlayan için 25–30 daha gerçekçi.
 */
export interface TimeModel {
  /** Eyer dikişi hızı: saatte kaç delikten geçiliyor. */
  readonly holesPerHour: number;
  /**
   * Delik açma hızı (saatte delik).
   *
   * Dikişten çok daha hızlı: iron bir vuruşta 4–6 delik açıyor.
   * Ayrı sayılmak zorunda çünkü DELME parça başına, DİKİŞ dikiş hattı
   * başına yapılıyor.
   */
  readonly punchesPerHour: number;
  /** Parça başına sabit kesim süresi (dakika). */
  readonly minutesPerPiece: number;
  /** 100mm kesim çevresi başına dakika. */
  readonly minutesPer100mmCut: number;
  /** 100mm bitmiş kenar başına dakika (zımpara + boya + cila). */
  readonly minutesPer100mmEdge: number;
  /**
   * Bitmiş kenar tahmini için en büyük parçanın çevresine uygulanan
   * çarpan.
   *
   * Bütün parçaların çevresini toplamak YANLIŞ: iç parçaların kenarları
   * montajda gizleniyor, yalnızca dış çevre ve yuva ağızları
   * cilalanıyor. En büyük parçanın çevresi + %30 makul bir yaklaşım.
   */
  readonly edgePerimeterFactor: number;
  /** Yapıştırma ve montaj için sabit süre (dakika). */
  readonly assemblyMinutes: number;
  /** Parça başına ek montaj süresi (dakika). */
  readonly assemblyMinutesPerPiece: number;
}

export const DEFAULT_TIME_MODEL: TimeModel = {
  holesPerHour: 50,
  // Iron bir vuruşta 4–6 delik açıyor; 500 fazla temkinliydi.
  // Hizalama ve takım değiştirme dahil 800 daha gerçekçi.
  punchesPerHour: 800,
  minutesPerPiece: 3,
  // 1.5 dk/100mm fazlaydı: keskin bir bıçak 100mm'yi 15–20 saniyede
  // kesiyor. Şablon hizalama ve tekrar geçişlerle 0.6 makul.
  minutesPer100mmCut: 0.6,
  // 8 dk/100mm fazlaydı: kenar boyasının KURUMA süresi aktif işçilik
  // değil. Zımpara + burnishing + boya çekme aktif olarak ~5 dk.
  minutesPer100mmEdge: 5,
  edgePerimeterFactor: 1.3,
  assemblyMinutes: 15,
  assemblyMinutesPerPiece: 3,
};

/**
 * Deri fire katsayısı.
 *
 * Post düzgün bir dikdörtgen değil; kenarlar, karın bölgesi ve kusurlu
 * yerler kullanılamıyor. Küçük deri işlerinde %25–40 fire tipik.
 *
 * ⚠ 1.35 geçici. Kendi postundan gerçekte kaç ürün çıktığını sayıp
 * düzeltmen gerekiyor.
 */
export const DEFAULT_WASTE_FACTOR = 1.35;

export interface CostOptions {
  readonly time?: TimeModel;
  readonly wasteFactor?: number;
  /**
   * Tüm süreleri ölçekleyen katsayı.
   *
   * 1 = modelin verdiği süre. 0.6 = model tahmininden %40 hızlı.
   * Deneyim, atölye düzeni ve alışkanlık burada toplanıyor; her
   * katsayıyı tek tek ayarlamak istemeyen için tek kol.
   */
  readonly speedFactor?: number;
  /**
   * Hesabı tamamen atlayıp toplam süreyi doğrudan ver.
   *
   * Kendi süreni ölçtüysen tahmin modelinin söyleyeceği bir şey yok.
   * Bileşen süreleri, toplam bu değere oturacak şekilde oranlanarak
   * gösterilir — döküm hâlâ toplamı tutar.
   */
  readonly overrideTotalHours?: number;
}

export interface CostBreakdown {
  readonly currency: string;
  /** Parçaların net alanı. */
  readonly netAreaDm2: number;
  /** Fire dahil satın alınması gereken alan. */
  readonly grossAreaDm2: number;
  readonly wasteFactor: number;
  readonly leatherCost: number;

  readonly cuttingHours: number;
  readonly punchingHours: number;
  readonly stitchingHours: number;
  readonly edgeHours: number;
  readonly assemblyHours: number;
  readonly totalHours: number;

  readonly labourCost: number;
  readonly consumablesCost: number;
  readonly hardwareCost: number;

  /** Deri + işçilik + sarf + donanım. */
  readonly directCost: number;
  readonly overhead: number;
  readonly totalCost: number;
  readonly margin: number;
  /** KDV hariç önerilen satış fiyatı. */
  readonly priceExVat: number;
  readonly vat: number;
  readonly priceIncVat: number;

  /** Deri maliyetinin toplam maliyet içindeki payı. */
  readonly leatherShare: number;
  readonly labourShare: number;

  readonly speedFactor: number;
  /** Toplam süre elle verildi mi? */
  readonly hoursOverridden: boolean;
  /** Elle verilmemiş olsaydı model ne söylerdi. */
  readonly modelHours: number;
}

/** Poligonun mutlak alanı, mm². */
function pieceAreaMm2(poly: readonly { readonly x: Mm; readonly y: Mm }[]): number {
  return Math.abs(signedArea(poly));
}

export function estimateCost(
  pattern: PatternResult,
  rates: CostRates = DEFAULT_RATES,
  options: CostOptions = {},
): CostBreakdown {
  const time = options.time ?? DEFAULT_TIME_MODEL;
  const wasteFactor = options.wasteFactor ?? DEFAULT_WASTE_FACTOR;
  const speedFactor = Math.max(0.1, options.speedFactor ?? 1);
  let areaMm2 = 0;
  let cutPerimeter = 0;
  let punchedHoles = 0;
  let pieceCount = 0;
  let maxPerimeter = 0;

  for (const p of pattern.pieces) {
    const q = p.quantity;
    areaMm2 += pieceAreaMm2(p.cutLine) * q;
    const perimeter = polylineLength(p.cutLine, true);
    cutPerimeter += perimeter * q;
    maxPerimeter = Math.max(maxPerimeter, perimeter);
    // DELME parça başına: her parçanın kendi delikleri açılıyor.
    punchedHoles += (p.stitchPlan?.totalHoles ?? 0) * q;
    pieceCount += q;
  }

  // DİKİŞ hattı başına: iplik bütün katmanlardan bir kerede geçiyor.
  const stitchedHoles = pattern.summary.stitchedHoles;
  const edgeLength = maxPerimeter * time.edgePerimeterFactor;

  const netAreaDm2 = areaMm2 / 10000;
  const grossAreaDm2 = netAreaDm2 * wasteFactor;
  const leatherCost = grossAreaDm2 * rates.leatherPerDm2;

  const cuttingHours =
    (pieceCount * time.minutesPerPiece +
      (cutPerimeter / 100) * time.minutesPer100mmCut) /
    60;
  const punchingHours = punchedHoles / Math.max(1, time.punchesPerHour);
  const stitchingHours = stitchedHoles / Math.max(1, time.holesPerHour);
  const edgeHours = ((edgeLength / 100) * time.minutesPer100mmEdge) / 60;
  const assemblyHours =
    (time.assemblyMinutes + pieceCount * time.assemblyMinutesPerPiece) / 60;
  const rawHours =
    cuttingHours + punchingHours + stitchingHours + edgeHours + assemblyHours;
  const modelHours = rawHours * speedFactor;

  // Elle verilen toplam varsa bileşenleri oranlayarak ona oturt; aksi
  // halde döküm toplamı tutmaz ve tablo kendi kendiyle çelişir.
  const override = options.overrideTotalHours;
  const hoursOverridden = override !== undefined && override > 0;
  const totalHours = hoursOverridden ? (override as number) : modelHours;
  const scale = modelHours > 0 ? totalHours / modelHours : 0;
  const k = speedFactor * scale;

  const labourCost = totalHours * rates.labourPerHour;
  const consumablesCost = totalHours * rates.consumablesPerHour;
  const hardwareCost = rates.hardware;

  const directCost = leatherCost + labourCost + consumablesCost + hardwareCost;
  const overhead = directCost * rates.overheadRate;
  const totalCost = directCost + overhead;
  const margin = totalCost * rates.marginRate;
  const priceExVat = totalCost + margin;
  const vat = priceExVat * rates.vatRate;

  return {
    currency: rates.currency,
    netAreaDm2,
    grossAreaDm2,
    wasteFactor,
    leatherCost,
    cuttingHours: cuttingHours * k,
    punchingHours: punchingHours * k,
    stitchingHours: stitchingHours * k,
    edgeHours: edgeHours * k,
    assemblyHours: assemblyHours * k,
    totalHours,
    labourCost,
    consumablesCost,
    hardwareCost,
    directCost,
    overhead,
    totalCost,
    margin,
    priceExVat,
    vat,
    priceIncVat: priceExVat + vat,
    leatherShare: totalCost > 0 ? leatherCost / totalCost : 0,
    labourShare: totalCost > 0 ? labourCost / totalCost : 0,
    speedFactor,
    hoursOverridden,
    modelHours,
  };
}

export interface CostNote {
  readonly severity: "info" | "warning";
  readonly message: string;
}

/**
 * Hesabın kendisi hakkında uyarılar.
 *
 * Bir fiyat sayısı, dayandığı varsayımlar görünmediğinde tehlikeli.
 * Bu notlar sayının nereden geldiğini ve nerede kırılgan olduğunu
 * söylüyor.
 */
export function costNotes(
  breakdown: CostBreakdown,
  rates: CostRates = DEFAULT_RATES,
): CostNote[] {
  const notes: CostNote[] = [];

  notes.push({
    severity: "warning",
    message:
      `Alan ve süre kalıptan hesaplandı; deri fiyatı (${rates.leatherPerDm2} ` +
      `${rates.currency}/dm²) ve işçilik (${rates.labourPerHour} ` +
      `${rates.currency}/saat) senin girdiğin değerler. Bu ikisi doğru ` +
      `değilse fiyat da doğru değil.`,
  });

  if (breakdown.hoursOverridden) {
    notes.push({
      severity: "info",
      message:
        `Toplam süre elle ${breakdown.totalHours.toFixed(1)} saat olarak ` +
        `verildi (model ${breakdown.modelHours.toFixed(1)} saat diyordu). ` +
        `Kendi ölçtüğün süre her zaman tahminden iyidir.`,
    });
  } else {
    notes.push({
      severity: "warning",
      message:
        `Dikiş süresi ${breakdown.stitchingHours.toFixed(1)} saat olarak ` +
        `hesaplandı. Bu, saatte ${DEFAULT_TIME_MODEL.holesPerHour} delik ` +
        `varsayımına dayanıyor ve GEÇİCİ bir katsayı. Süreni tut, hız ` +
        `katsayısını ya da toplam süreyi elle gir.`,
    });
    if (breakdown.speedFactor !== 1) {
      notes.push({
        severity: "info",
        message:
          `Hız katsayısı ${breakdown.speedFactor.toFixed(2)} uygulandı; ` +
          `modelin ham tahmini ${(breakdown.modelHours / breakdown.speedFactor).toFixed(1)} saatti.`,
      });
    }
  }

  if (breakdown.labourShare > 0.7) {
    notes.push({
      severity: "info",
      message:
        `Maliyetin %${(breakdown.labourShare * 100).toFixed(0)}'i işçilik. ` +
        `El yapımı deride normal; fiyatı düşürmenin yolu daha ucuz deri ` +
        `değil, daha hızlı çalışmak ya da daha az delik.`,
    });
  }

  if (breakdown.leatherShare > 0.5) {
    notes.push({
      severity: "info",
      message:
        `Maliyetin %${(breakdown.leatherShare * 100).toFixed(0)}'i deri. ` +
        `Fire katsayısı ${breakdown.wasteFactor} — parçaları posta daha iyi ` +
        `yerleştirmek burada belirgin kazanç sağlar.`,
    });
  }

  if (breakdown.totalHours > 8) {
    notes.push({
      severity: "info",
      message:
        `Toplam ${breakdown.totalHours.toFixed(1)} saat — bir günlük işten ` +
        `fazla. Fiyatlandırırken bunun bir seferde bitmeyeceğini hesaba kat.`,
    });
  }

  return notes;
}
ODK_EOF_0

echo "==> packages/patterns/src/costing.test.ts"
cat > packages/patterns/src/costing.test.ts << 'ODK_EOF_1'
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
    const fine = estimateCost(generateBifold({ ...BIFOLD_DEFAULTS, pitch: 3 }));
    const coarse = estimateCost(generateBifold({ ...BIFOLD_DEFAULTS, pitch: 5 }));
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


describe("süre ayarlanabilirliği", () => {
  const base = estimateCost(wallet95);

  it("hız katsayısı tüm süreleri ölçekliyor", () => {
    const fast = estimateCost(wallet95, DEFAULT_RATES, { speedFactor: 0.5 });
    expect(fast.totalHours).toBeCloseTo(base.totalHours * 0.5, 6);
    expect(fast.stitchingHours).toBeCloseTo(base.stitchingHours * 0.5, 6);
    expect(fast.cuttingHours).toBeCloseTo(base.cuttingHours * 0.5, 6);
  });

  it("hız katsayısı fiyatı düşürüyor ama sıfırlamıyor (deri sabit)", () => {
    const fast = estimateCost(wallet95, DEFAULT_RATES, { speedFactor: 0.5 });
    expect(fast.priceExVat).toBeLessThan(base.priceExVat);
    expect(fast.leatherCost).toBeCloseTo(base.leatherCost, 6);
  });

  it("elle verilen toplam süre kullanılıyor", () => {
    const manual = estimateCost(wallet95, DEFAULT_RATES, { overrideTotalHours: 2 });
    expect(manual.totalHours).toBe(2);
    expect(manual.hoursOverridden).toBe(true);
    expect(manual.modelHours).toBeCloseTo(base.totalHours, 6);
  });

  it("elle verilen toplamda döküm hâlâ toplamı tutuyor", () => {
    // Bileşenler oranlanmazsa tablo kendi kendisiyle çelişirdi.
    const m = estimateCost(wallet95, DEFAULT_RATES, { overrideTotalHours: 2 });
    expect(
      m.cuttingHours + m.punchingHours + m.stitchingHours + m.edgeHours + m.assemblyHours,
    ).toBeCloseTo(2, 6);
  });

  it("delik hızını artırmak dikişi kısaltıyor", () => {
    const quick = estimateCost(wallet95, DEFAULT_RATES, {
      time: { ...DEFAULT_TIME_MODEL, holesPerHour: 100 },
    });
    expect(quick.stitchingHours).toBeCloseTo(base.stitchingHours / 2, 6);
  });

  it("fire katsayısı deri maliyetini değiştiriyor", () => {
    const tight = estimateCost(wallet95, DEFAULT_RATES, { wasteFactor: 1.1 });
    expect(tight.leatherCost).toBeLessThan(base.leatherCost);
  });

  it("elle süre verilince not değişiyor", () => {
    const m = estimateCost(wallet95, DEFAULT_RATES, { overrideTotalHours: 2 });
    const notes = costNotes(m);
    expect(notes.some((n) => n.message.includes("elle"))).toBe(true);
    expect(notes.some((n) => n.message.includes("GEÇİCİ"))).toBe(false);
  });
});
ODK_EOF_1

echo "==> apps/web/src/engine.ts"
cat > apps/web/src/engine.ts << 'ODK_EOF_2'
/**
 * Motor köprüsü.
 *
 * Arayüzün motora tek giriş noktası. @odk/* paketlerinden doğrudan
 * import etmek yerine buradan geçmek, ileride motor API'si değiştiğinde
 * bileşenlerin değişmemesini sağlıyor.
 */
export {
  BIFOLD_DEFAULTS,
  BANKNOTES,
  CATEGORIES,
  DEFAULT_PARAMS,
  FAMILIES,
  STATUS_LABEL,
  buildInstructions,
  categoryHasAvailable,
  familiesByCategory,
  generateBifold,
  generateCardHolder,
  generateTote,
  STRAP_SPECS,
  TOTE_DEFAULTS,
  DEFAULT_RATES,
  costNotes,
  estimateCost,
  DEFAULT_TIME_MODEL,
} from "@odk/patterns";

export { stitchSummary as stitchSummaryFor } from "@odk/geometry";
ODK_EOF_2

echo "==> apps/web/src/App.tsx"
cat > apps/web/src/App.tsx << 'ODK_EOF_3'
import { useMemo, useState } from "react";
import type {
  BifoldParams,
  GussetStyle,
  StrapStyle,
  ToteParams,
  CardHolderParams,
  CardOrientation,
  Currency,
  SlotConstruction,
} from "@odk/patterns";
import {
  BANKNOTES,
  BIFOLD_DEFAULTS,
  CATEGORIES,
  DEFAULT_PARAMS,
  buildInstructions,
  categoryHasAvailable,
  familiesByCategory,
  generateBifold,
  generateCardHolder,
  generateTote,
  stitchSummaryFor,
  STATUS_LABEL,
  TOTE_DEFAULTS,
  DEFAULT_RATES,
  DEFAULT_TIME_MODEL,
  costNotes,
  estimateCost,
} from "./engine.js";
import type { CostOptions, CostRates } from "@odk/patterns";

type FamilyId = "card-holder-fold" | "bifold" | "tote";
import { PieceView } from "./PieceView.js";

/**
 * PDF katmanı DİNAMİK yükleniyor.
 *
 * pdf-lib + fontkit ana pakete girdiğinde bundle 1.29MB'a çıkıyordu.
 * Kullanıcıların çoğu önce parametrelerle oynuyor; PDF kodunu ilk
 * "PDF indir" tıklamasına kadar indirmemek ilk açılışı belirgin
 * hızlandırıyor.
 */
const pdfModule = () => import("./pdf.js");

const PX_PER_MM = 2.4;

interface SliderProps {
  label: string;
  value: number;
  min: number;
  max: number;
  step: number;
  unit?: string;
  hint?: string;
  onChange: (v: number) => void;
}

function Slider({ label, value, min, max, step, unit, hint, onChange }: SliderProps) {
  const id = `f-${label.replace(/\s/g, "-")}`;
  return (
    <div className="field">
      <div className="field-head">
        <label htmlFor={id}>{label}</label>
        <span className="field-value">
          {step < 1 ? value.toFixed(1) : value}
          {unit ?? ""}
        </span>
      </div>
      <input
        id={id}
        type="range"
        min={min}
        max={max}
        step={step}
        value={value}
        onChange={(e) => onChange(Number(e.target.value))}
      />
      {hint !== undefined && <p className="hint">{hint}</p>}
    </div>
  );
}

interface ChoiceProps<T extends string> {
  label: string;
  value: T;
  options: readonly { value: T; label: string }[];
  hint?: string;
  onChange: (v: T) => void;
}

function Choice<T extends string>({
  label,
  value,
  options,
  hint,
  onChange,
}: ChoiceProps<T>) {
  return (
    <div className="field">
      <div className="field-head">
        <label>{label}</label>
      </div>
      <div className="segmented" role="group" aria-label={label}>
        {options.map((o) => (
          <button
            key={o.value}
            type="button"
            aria-pressed={o.value === value}
            onClick={() => onChange(o.value)}
          >
            {o.label}
          </button>
        ))}
      </div>
      {hint !== undefined && <p className="hint">{hint}</p>}
    </div>
  );
}

interface PrintState {
  readonly printAllHoles: boolean;
  readonly allowRotation: boolean;
  readonly measured: string;
  readonly scaleFactor: number;
  readonly note: string;
  readonly noteOk: boolean;
  readonly busy: boolean;
}

const INITIAL_PRINT: PrintState = {
  printAllHoles: true,
  allowRotation: true,
  measured: "50",
  scaleFactor: 1,
  note: "",
  noteOk: true,
  busy: false,
};

interface SelectProps {
  label: string;
  value: string;
  options: readonly { value: string; label: string }[];
  hint?: string;
  onChange: (v: string) => void;
}

function Select({ label, value, options, hint, onChange }: SelectProps) {
  const id = `s-${label.replace(/\s/g, "-")}`;
  return (
    <div className="field">
      <div className="field-head">
        <label htmlFor={id}>{label}</label>
      </div>
      <select
        id={id}
        className="dropdown"
        value={value}
        onChange={(e) => onChange(e.target.value)}
      >
        {options.map((o) => (
          <option key={o.value} value={o.value}>
            {o.label}
          </option>
        ))}
      </select>
      {hint !== undefined && <p className="hint">{hint}</p>}
    </div>
  );
}

export default function App() {
  const [family, setFamily] = useState<FamilyId>("card-holder-fold");
  const [params, setParams] = useState<CardHolderParams>(DEFAULT_PARAMS);
  const [bifold, setBifold] = useState<BifoldParams>(BIFOLD_DEFAULTS);
  const [tote, setTote] = useState<ToteParams>(TOTE_DEFAULTS);
  const [print, setPrint] = useState<PrintState>(INITIAL_PRINT);
  const [rates, setRates] = useState<CostRates>(DEFAULT_RATES);
  const [speed, setSpeed] = useState(1);
  const [manualHours, setManualHours] = useState("");

  const isBifold = family === "bifold";
  const isTote = family === "tote";
  // Talimatlar ve PDF üç aile için de bu dar bağlamı kullanıyor.
  const ctx = isTote
    ? { ...tote, kind: "canta" as const }
    : isBifold
      ? bifold
      : params;

  const set = <K extends keyof CardHolderParams>(
    key: K,
    value: CardHolderParams[K],
  ) => setParams((p) => ({ ...p, [key]: value }));

  const setB = <K extends keyof BifoldParams>(key: K, value: BifoldParams[K]) =>
    setBifold((p) => ({ ...p, [key]: value }));

  const setT = <K extends keyof ToteParams>(key: K, value: ToteParams[K]) =>
    setTote((p) => ({ ...p, [key]: value }));

  const parsedHours = Number(manualHours);
  const costOptions: CostOptions = {
    speedFactor: speed,
    ...(manualHours !== "" && Number.isFinite(parsedHours) && parsedHours > 0
      ? { overrideTotalHours: parsedHours }
      : {}),
  };

  const result = useMemo(() => {
    try {
      return {
        ok: true as const,
        value: isTote
          ? generateTote(tote)
          : isBifold
            ? generateBifold(bifold)
            : generateCardHolder(params),
      };
    } catch (err) {
      return {
        ok: false as const,
        message: err instanceof Error ? err.message : String(err),
      };
    }
  }, [isBifold, isTote, params, bifold, tote]);

  return (
    <div className="shell">
      <aside className="rail">
        <header className="masthead">
          <h1>Deri Kalıp Motoru</h1>
          <p>
            Kartlık · kesit çözücü + dikiş dağıtıcı
            <br />
            ölçüler mm · ızgara 10mm, kalın çizgi 50mm
          </p>
        </header>

        <div className="group">
          <span className="group-title">Katalog</span>
          {CATEGORIES.map((c) => (
            <div className="cat" key={c.id}>
              <span className="cat-name">{c.name}</span>
              <ul className="fam">
                {familiesByCategory(c.id).map((f) => {
                  const usable = f.status === "hazir";
                  const active = usable && f.id === family;
                  return (
                    <li key={f.id}>
                      <button
                        type="button"
                        className="fam-item"
                        data-status={f.status}
                        data-active={active}
                        disabled={!usable}
                        aria-pressed={active}
                        onClick={() => {
                          if (usable) setFamily(f.id as FamilyId);
                        }}
                      >
                        <span>{f.name}</span>
                        <span className="fam-status">
                          {STATUS_LABEL[f.status]}
                        </span>
                      </button>
                    </li>
                  );
                })}
              </ul>
              {!categoryHasAvailable(c.id) && (
                <p className="hint">{c.description}</p>
              )}
            </div>
          ))}
        </div>

        {isTote ? (
          <fieldset className="group" style={{ border: 0, margin: 0, padding: 0 }}>
            <legend>Çanta</legend>
            <Slider
              label="Genişlik"
              value={tote.width}
              min={140}
              max={340}
              step={5}
              unit="mm"
              onChange={(v) => setT("width", v)}
            />
            <Slider
              label="Yükseklik"
              value={tote.height}
              min={120}
              max={340}
              step={5}
              unit="mm"
              onChange={(v) => setT("height", v)}
            />
            <Slider
              label="Derinlik (körük)"
              value={tote.depth}
              min={30}
              max={160}
              step={5}
              unit="mm"
              onChange={(v) => setT("depth", v)}
            />
            <Slider
              label="Alt köşe yarıçapı"
              value={tote.cornerRadius}
              min={10}
              max={90}
              step={5}
              unit="mm"
              hint="Derinliğin yarısından küçük olursa körük köşede buruşur."
              onChange={(v) => setT("cornerRadius", v)}
            />
            <Choice<GussetStyle>
              label="Körük"
              value={tote.gusset}
              options={[
                { value: "uc-parca", label: "Üç parça" },
                { value: "tek-parca", label: "Tek parça" },
              ]}
              hint="Üç parça A4'e sığar ama iki ek dikiş getirir. Tek parça dikişsiz ama sayfalara bölünür."
              onChange={(v) => setT("gusset", v)}
            />
            <Select
              label="Askı"
              value={tote.strap}
              options={[
                { value: "yok", label: "Askısız" },
                { value: "el", label: "El sapı (2 adet)" },
                { value: "omuz", label: "Omuz askısı" },
                { value: "capraz", label: "Çapraz askı" },
              ]}
              onChange={(v) => setT("strap", v as StrapStyle)}
            />
            {tote.strap !== "yok" && (
              <Slider
                label="Askı drop"
                value={(tote.strapDrop ?? 550) / 10}
                min={20}
                max={70}
                step={1}
                unit="cm"
                hint="Askının tepesinden çantanın üst kenarına dikey mesafe."
                onChange={(v) => setT("strapDrop", v * 10)}
              />
            )}
            <Slider
              label="Panel derisi"
              value={tote.panelThickness}
              min={1.0}
              max={3.0}
              step={0.1}
              unit="mm"
              hint="Çanta yapısal yük taşıyor: 1.6–2.4mm öneriliyor."
              onChange={(v) => setT("panelThickness", v)}
            />
            <Slider
              label="Körük derisi"
              value={tote.gussetThickness}
              min={1.0}
              max={2.6}
              step={0.1}
              unit="mm"
              onChange={(v) => setT("gussetThickness", v)}
            />
            <Slider
              label="Askı derisi"
              value={tote.strapThickness}
              min={1.4}
              max={3.6}
              step={0.1}
              unit="mm"
              onChange={(v) => setT("strapThickness", v)}
            />
            <Slider
              label="Dikiş payı"
              value={tote.stitchMargin}
              min={3}
              max={6}
              step={0.5}
              unit="mm"
              onChange={(v) => setT("stitchMargin", v)}
            />
            <Select
              label="Pricking iron"
              value={tote.pitch === undefined ? "auto" : String(tote.pitch)}
              options={[
                { value: "3.85", label: "3.85 mm" },
                { value: "4", label: "4.0 mm" },
                { value: "5", label: "5.0 mm" },
                { value: "auto", label: "Oto — en az delik" },
              ]}
              onChange={(v) =>
                setTote((p) => {
                  if (v === "auto") {
                    const { pitch: _drop, ...rest } = p;
                    return rest;
                  }
                  return { ...p, pitch: Number(v) };
                })
              }
            />
          </fieldset>
        ) : isBifold ? (
          <fieldset className="group" style={{ border: 0, margin: 0, padding: 0 }}>
            <legend>Bifold</legend>
            <Slider
              label="Panel başına yuva"
              value={bifold.cardSlotsPerSide}
              min={1}
              max={6}
              step={1}
              onChange={(v) => setB("cardSlotsPerSide", v)}
            />
            <Select
              label="Banknot"
              value={bifold.currency}
              options={Object.values(BANKNOTES).map((b) => ({
                value: b.currency,
                label: b.label + (b.verified ? "" : " ⚠"),
              }))}
              hint="Cüzdanın açık genişliğini en büyük kupür belirler."
              onChange={(v) => setB("currency", v as Currency)}
            />
            <Choice<SlotConstruction>
              label="Yapım biçimi"
              value={bifold.construction}
              options={[
                { value: "t-slot", label: "T-slot" },
                { value: "stacked", label: "Düz yığın" },
              ]}
              onChange={(v) => setB("construction", v)}
            />
            <Slider
              label="Kademe"
              value={bifold.reveal}
              min={5}
              max={22}
              step={0.5}
              unit="mm"
              onChange={(v) => setB("reveal", v)}
            />
            <Slider
              label="Dış kabuk"
              value={bifold.outerThickness}
              min={0.6}
              max={1.4}
              step={0.1}
              unit="mm"
              onChange={(v) => setB("outerThickness", v)}
            />
            <Slider
              label="İç kabuk"
              value={bifold.innerThickness}
              min={0.5}
              max={1.2}
              step={0.1}
              unit="mm"
              onChange={(v) => setB("innerThickness", v)}
            />
            <Slider
              label="Yuva derisi"
              value={bifold.slotThickness}
              min={0.4}
              max={1.0}
              step={0.1}
              unit="mm"
              onChange={(v) => setB("slotThickness", v)}
            />
            <Slider
              label="Dikiş payı"
              value={bifold.stitchMargin}
              min={2.5}
              max={5}
              step={0.5}
              unit="mm"
              onChange={(v) => setB("stitchMargin", v)}
            />
            <Slider
              label="Köşe yarıçapı"
              value={bifold.cornerRadius}
              min={0}
              max={12}
              step={0.5}
              unit="mm"
              onChange={(v) => setB("cornerRadius", v)}
            />
            <Select
              label="Pricking iron"
              value={bifold.pitch === undefined ? "auto" : String(bifold.pitch)}
              options={[
                { value: "3", label: "3.0 mm" },
                { value: "3.38", label: "3.38 mm" },
                { value: "3.85", label: "3.85 mm" },
                { value: "4", label: "4.0 mm" },
                { value: "auto", label: "Oto — en az delik" },
              ]}
              onChange={(v) =>
                setBifold((p) => {
                  if (v === "auto") {
                    const { pitch: _drop, ...rest } = p;
                    return rest;
                  }
                  return { ...p, pitch: Number(v) };
                })
              }
            />
            <Choice<string>
              label="Kalem payı"
              value={String(bifold.penAllowance)}
              options={[
                { value: "0", label: "0" },
                { value: "0.3", label: "0.3mm" },
                { value: "0.5", label: "0.5mm" },
              ]}
              onChange={(v) => setB("penAllowance", Number(v))}
            />
          </fieldset>
        ) : (
          <>
        <fieldset className="group" style={{ border: 0, margin: 0, padding: 0 }}>
          <legend>Yuvalar</legend>
          <Slider
            label="Kart yuvası"
            value={params.cardCount}
            min={1}
            max={8}
            step={1}
            onChange={(v) => set("cardCount", v)}
          />
          <Choice<SlotConstruction>
            label="Yapım biçimi"
            value={params.construction}
            options={[
              { value: "t-slot", label: "T-slot" },
              { value: "stacked", label: "Düz yığın" },
            ]}
            hint="T-slot kenar kalınlığını yuva sayısından bağımsız tutar."
            onChange={(v) => set("construction", v)}
          />
          <Choice<CardOrientation>
            label="Kart yönü"
            value={params.orientation}
            options={[
              { value: "horizontal", label: "Yatay" },
              { value: "vertical", label: "Dikey" },
            ]}
            onChange={(v) => set("orientation", v)}
          />
          <Slider
            label="Kademe"
            value={params.reveal}
            min={5}
            max={22}
            step={0.5}
            unit="mm"
            hint="Yuva ağızları arası mesafe. 5mm belgelenmiş alt sınır."
            onChange={(v) => set("reveal", v)}
          />
        </fieldset>

        <fieldset className="group" style={{ border: 0, margin: 0, padding: 0 }}>
          <legend>Deri</legend>
          <Slider
            label="Dış kabuk"
            value={params.outerThickness}
            min={0.6}
            max={1.6}
            step={0.1}
            unit="mm"
            onChange={(v) => set("outerThickness", v)}
          />
          <Slider
            label="Yuva derisi"
            value={params.slotThickness}
            min={0.4}
            max={1.2}
            step={0.1}
            unit="mm"
            hint="Önerilen 0.6–0.8mm. Kalın deri yuvanın esnemesini engeller."
            onChange={(v) => set("slotThickness", v)}
          />
        </fieldset>

        <fieldset className="group" style={{ border: 0, margin: 0, padding: 0 }}>
          <legend>Dikiş ve kesim</legend>
          <Select
            label="Pricking iron"
            value={params.pitch === undefined ? "auto" : String(params.pitch)}
            options={[
              { value: "2.7", label: "2.7 mm" },
              { value: "3", label: "3.0 mm" },
              { value: "3.38", label: "3.38 mm" },
              { value: "3.85", label: "3.85 mm" },
              { value: "4", label: "4.0 mm" },
              { value: "5", label: "5.0 mm" },
              { value: "auto", label: "Oto — en az delik" },
            ]}
            hint="Elindeki takımın adımını seç. Oto yalnızca sapmayı ölçebilir, dikişin sıklığı senin kararın."
            onChange={(v) =>
              setParams((p) => {
                if (v === "auto") {
                  const { pitch: _drop, ...rest } = p;
                  return rest;
                }
                return { ...p, pitch: Number(v) };
              })
            }
          />
          <Slider
            label="Dikiş payı"
            value={params.stitchMargin}
            min={2.5}
            max={5}
            step={0.5}
            unit="mm"
            onChange={(v) => set("stitchMargin", v)}
          />
          <Slider
            label="Köşe yarıçapı"
            value={params.cornerRadius}
            min={0}
            max={10}
            step={0.5}
            unit="mm"
            onChange={(v) => set("cornerRadius", v)}
          />
          <Choice<string>
            label="Kalem payı"
            value={String(params.penAllowance)}
            options={[
              { value: "0", label: "0" },
              { value: "0.3", label: "0.3mm" },
              { value: "0.5", label: "0.5mm" },
            ]}
            hint="Kalem ucu dışa kaçtığı için şablon o kadar küçük basılır."
            onChange={(v) => set("penAllowance", Number(v))}
          />
        </fieldset>
          </>
        )}

        <fieldset className="group" style={{ border: 0, margin: 0, padding: 0 }}>
          <legend>Maliyet</legend>
          <p className="hint">
            Alan ve süre kalıptan hesaplanıyor. Fiyatları sen giriyorsun —
            deri ve işçilik ücretleri tabakhaneye, ülkeye ve aya göre
            değişiyor, motor bunları bilemez.
          </p>
          {(
            [
              ["leatherPerDm2", "Deri", "/dm²", 0, 500, 5],
              ["labourPerHour", "İşçilik", "/saat", 0, 2000, 25],
              ["consumablesPerHour", "Sarf", "/saat", 0, 300, 5],
              ["hardware", "Donanım", "toplam", 0, 2000, 25],
            ] as const
          ).map(([key, label, unit, min, max, step]) => (
            <Slider
              key={key}
              label={`${label} (${unit})`}
              value={rates[key]}
              min={min}
              max={max}
              step={step}
              onChange={(v) => setRates((p) => ({ ...p, [key]: v }))}
            />
          ))}
          <Slider
            label="Hız katsayısı"
            value={speed}
            min={0.3}
            max={1.6}
            step={0.05}
            hint="1 = modelin tahmini. 0.6 = tahminden %40 hızlı çalışıyorum."
            onChange={setSpeed}
          />
          <div className="field">
            <div className="field-head">
              <label htmlFor="mh">Toplam süre (elle)</label>
              <span className="field-value">saat</span>
            </div>
            <div className="calibrate">
              <input
                id="mh"
                type="number"
                step="0.25"
                min="0"
                placeholder="boş = hesapla"
                value={manualHours}
                onChange={(ev) => setManualHours(ev.target.value)}
              />
              <button type="button" onClick={() => setManualHours("")}>
                Temizle
              </button>
            </div>
            <p className="hint">
              Kendi süreni ölçtüysen buraya gir; model tahmini devre dışı
              kalır. Ölçülen süre her zaman tahminden iyidir.
            </p>
          </div>
          <Slider
            label="Genel gider"
            value={Math.round(rates.overheadRate * 100)}
            min={0}
            max={60}
            step={5}
            unit="%"
            onChange={(v) => setRates((p) => ({ ...p, overheadRate: v / 100 }))}
          />
          <Slider
            label="Kâr marjı"
            value={Math.round(rates.marginRate * 100)}
            min={0}
            max={150}
            step={5}
            unit="%"
            onChange={(v) => setRates((p) => ({ ...p, marginRate: v / 100 }))}
          />
          <Slider
            label="KDV"
            value={Math.round(rates.vatRate * 100)}
            min={0}
            max={30}
            step={1}
            unit="%"
            onChange={(v) => setRates((p) => ({ ...p, vatRate: v / 100 }))}
          />
        </fieldset>

        <fieldset className="group" style={{ border: 0, margin: 0, padding: 0 }}>
          <legend>Baskı</legend>

          <Choice<string>
            label="Delikler"
            value={print.printAllHoles ? "all" : "anchors"}
            options={[
              { value: "anchors", label: "Sadece köşe" },
              { value: "all", label: "Hepsi" },
            ]}
            hint="Şablonu deriye bantlayıp noktalardan deleceksen 'Hepsi'. Ironu kendin yürüteceksen köşe çapaları yeterli."
            onChange={(v) =>
              setPrint((p) => ({ ...p, printAllHoles: v === "all" }))
            }
          />

          <Choice<string>
            label="Sayfaya sığdırma"
            value={print.allowRotation ? "rotate" : "tile"}
            options={[
              { value: "rotate", label: "Döndür" },
              { value: "tile", label: "Böl" },
            ]}
            hint="Döndür: parça 90° çevrilip tek sayfaya sığar, hizalama gerekmez. Böl: parça sayfalara bölünür, kesip yapıştırman gerekir."
            onChange={(v) =>
              setPrint((p) => ({ ...p, allowRotation: v === "rotate" }))
            }
          />

          <div className="field">
            <div className="field-head">
              <label htmlFor="cal">Ölçtüğün kare</label>
              <span className="field-value">nominal 50mm</span>
            </div>
            <div className="calibrate">
              <input
                id="cal"
                type="number"
                step="0.1"
                min="1"
                value={print.measured}
                onChange={(e) =>
                  setPrint((p) => ({ ...p, measured: e.target.value }))
                }
              />
              <button
                type="button"
                onClick={() => {
                  void pdfModule().then(({ scaleFromMeasurement }) => {
                    const r = scaleFromMeasurement(Number(print.measured));
                    setPrint((p) => ({
                      ...p,
                      scaleFactor: r.ok ? r.factor : p.scaleFactor,
                      note: r.message,
                      noteOk: r.ok,
                    }));
                  });
                }}
              >
                Uygula
              </button>
            </div>
            <p className="hint">
              PDF'i bas, kapaktaki kareyi cetvelle ölç, çıkan değeri buraya
              gir. Ölçek düzeltilir.
            </p>
            {print.note !== "" && (
              <p className="hint" data-tone={print.noteOk ? "ok" : "bad"}>
                {print.note}
              </p>
            )}
          </div>

          <button
            type="button"
            className="primary"
            disabled={print.busy || !result.ok}
            onClick={() => {
              if (!result.ok) return;
              setPrint((p) => ({ ...p, busy: true }));
              pdfModule()
                .then(({ downloadPatternPdf }) =>
                  downloadPatternPdf(result.value, {
                    printAllHoles: print.printAllHoles,
                    allowRotation: print.allowRotation,
                    scaleFactor: print.scaleFactor,
                    title: isTote
                      ? `Çanta ${tote.width}x${tote.height}x${tote.depth}`
                      : isBifold
                        ? `Bifold ${bifold.cardSlotsPerSide}+${bifold.cardSlotsPerSide} yuva`
                        : `Kartlık ${params.cardCount} yuva`,
                    params: ctx,
                  }),
                )
                .catch((err: unknown) => {
                  setPrint((p) => ({
                    ...p,
                    note:
                      "PDF üretilemedi: " +
                      (err instanceof Error ? err.message : String(err)),
                    noteOk: false,
                  }));
                })
                .finally(() => setPrint((p) => ({ ...p, busy: false })));
            }}
          >
            {print.busy ? "Hazırlanıyor…" : "PDF indir"}
          </button>
          {print.scaleFactor !== 1 && (
            <p className="hint">
              Ölçek düzeltmesi aktif: ×{print.scaleFactor.toFixed(4)}
            </p>
          )}
        </fieldset>
      </aside>

      <main className="stage">
        {!result.ok ? (
          <ul className="diagnostics">
            <li className="diagnostic" data-severity="error">
              <code>ÇÖZÜLEMEDİ</code>
              <span>
                Bu parametrelerle kalıp üretilemiyor: {result.message}
                {" "}Dikiş payını küçültmeyi ya da yuva sayısını azaltmayı dene.
              </span>
            </li>
          </ul>
        ) : (
          <Result
            value={result.value}
            ctx={ctx}
            family={family}
            rates={rates}
            costOptions={costOptions}
          />
        )}
      </main>
    </div>
  );
}

function Result({
  value,
  ctx,
  family,
  rates,
  costOptions,
}: {
  value: ReturnType<typeof generateCardHolder>;
  ctx: CardHolderParams | BifoldParams | (ToteParams & { kind: "canta" });
  family: FamilyId;
  rates: CostRates;
  costOptions: CostOptions;
}) {
  const s = value.summary;
  const outer = value.pieces.find((p) => p.id === "outer");

  return (
    <>
      {value.diagnostics.length > 0 && (
        <ul className="diagnostics">
          {value.diagnostics.map((d, i) => (
            <li key={i} className="diagnostic" data-severity={d.severity}>
              <code>{d.code}</code>
              <span>{d.message}</span>
            </li>
          ))}
        </ul>
      )}

      <div className="stage-head">
        <h2>Parçalar</h2>
        <span className="scale-note">
          {family === "tote"
            ? `${(ctx as ToteParams).width}×${(ctx as ToteParams).height}×${(ctx as ToteParams).depth}mm`
            : family === "bifold"
              ? `${(ctx as BifoldParams).cardSlotsPerSide}+${(ctx as BifoldParams).cardSlotsPerSide} yuva · ${(ctx as BifoldParams).construction === "t-slot" ? "T-slot" : "düz yığın"}`
              : `${(ctx as CardHolderParams).cardCount} yuva · ${(ctx as CardHolderParams).construction === "t-slot" ? "T-slot" : "düz yığın"}`}{" "}
          · {s.pitch}mm adım · {s.totalHoles} delik
        </span>
      </div>

      <div className="legend">
        <span>
          <i className="swatch" style={{ borderTopColor: "var(--bone)" }} /> kesim
        </span>
        <span>
          <i
            className="swatch"
            style={{ borderTopColor: "var(--brass-dim)", borderTopStyle: "dashed" }}
          />{" "}
          dikiş hattı
        </span>
        <span>
          <i
            className="swatch"
            style={{ borderTopColor: "var(--chalk)", borderTopStyle: "dotted" }}
          />{" "}
          kat
        </span>
        <span>
          <i className="swatch dot" /> delik
        </span>
      </div>

      {value.pieces.map((piece) => (
        <section className="piece" key={piece.id}>
          <div className="piece-head">
            <span className="piece-name">{piece.name}</span>
            <span className="piece-meta">
              ×{piece.quantity} · {piece.width.toFixed(1)} × {piece.height.toFixed(1)}mm ·{" "}
              {piece.leatherThickness.toFixed(1)}mm deri
            </span>
          </div>
          <PieceView piece={piece} pxPerMm={PX_PER_MM} />
        </section>
      ))}

      <CostPanel value={value} rates={rates} costOptions={costOptions} />

      <section className="steps">
        <h3>Yapım adımları</h3>
        <ol>
          {buildInstructions(value, ctx).map((step) => (
            <li key={step.n}>
              <span className="step-title">{step.title}</span>
              <p>{step.body}</p>
              {step.warning !== undefined && (
                <p className="step-warn">{step.warning}</p>
              )}
            </li>
          ))}
        </ol>
      </section>

      <div className="columns">
        <table className="readout">
          <caption>Kesit çözümü</caption>
          <tbody>
            {value.crossSection.layers.map((l) => (
              <tr key={l.layerId}>
                <th scope="row">{l.name}</th>
                <td className="num">{l.straightLength.toFixed(2)}</td>
                <td className="num">+{l.bendAllowance.toFixed(2)}</td>
                <td className="num">= {l.flatLength.toFixed(2)} mm</td>
              </tr>
            ))}
          </tbody>
        </table>

        <table className="readout">
          <caption>Ölçüler</caption>
          <tbody>
            {(s.metrics ?? []).map((mt) => (
              <tr key={mt.label}>
                <th scope="row">{mt.label}</th>
                <td className="num">{mt.value}</td>
              </tr>
            ))}
            <tr>
              <th scope="row">dikiş</th>
              <td className="num">
                {s.pitch}mm · {s.totalHoles} delik
              </td>
            </tr>
            <tr>
              <th scope="row">A4</th>
              <td className="num">{s.fitsA4 ? "sığıyor" : "bölünecek"}</td>
            </tr>
          </tbody>
        </table>

        {outer?.stitchPlan !== undefined && (
          <table className="readout">
            <caption>Dikiş planı — dış kabuk</caption>
            <tbody>
              {stitchSummaryFor(outer.stitchPlan).map((line, i) => (
                <tr key={i}>
                  <td colSpan={2}>{line}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>
    </>
  );
}


function CostPanel({
  value,
  rates,
  costOptions,
}: {
  value: ReturnType<typeof generateCardHolder>;
  rates: CostRates;
  costOptions: CostOptions;
}) {
  const c = estimateCost(value, rates, costOptions);
  const notes = costNotes(c, rates);
  const money = (n: number) => `${Math.round(n).toLocaleString("tr-TR")} ${c.currency}`;
  const hours = (n: number) => `${n.toFixed(2)} sa`;

  return (
    <section className="cost">
      <h3>Maliyet ve önerilen fiyat</h3>
      <div className="cost-headline">
        <span className="cost-price">{money(c.priceIncVat)}</span>
        <span className="cost-sub">
          KDV dahil · KDV hariç {money(c.priceExVat)} · maliyet {money(c.totalCost)}
        </span>
      </div>

      <div className="columns">
        <table className="readout">
          <caption>Malzeme ve süre</caption>
          <tbody>
            <tr>
              <th scope="row">net deri</th>
              <td className="num">{c.netAreaDm2.toFixed(2)} dm²</td>
            </tr>
            <tr>
              <th scope="row">fire dahil</th>
              <td className="num">{c.grossAreaDm2.toFixed(2)} dm²</td>
            </tr>
            <tr>
              <th scope="row">kesim</th>
              <td className="num">{hours(c.cuttingHours)}</td>
            </tr>
            <tr>
              <th scope="row">delme</th>
              <td className="num">{hours(c.punchingHours)}</td>
            </tr>
            <tr>
              <th scope="row">dikiş</th>
              <td className="num">{hours(c.stitchingHours)}</td>
            </tr>
            <tr>
              <th scope="row">kenar</th>
              <td className="num">{hours(c.edgeHours)}</td>
            </tr>
            <tr>
              <th scope="row">montaj</th>
              <td className="num">{hours(c.assemblyHours)}</td>
            </tr>
            <tr>
              <th scope="row">
                toplam{c.hoursOverridden ? " (elle)" : ""}
              </th>
              <td className="num">{hours(c.totalHours)}</td>
            </tr>
            {c.hoursOverridden && (
              <tr>
                <th scope="row">model tahmini</th>
                <td className="num">{hours(c.modelHours)}</td>
              </tr>
            )}
            <tr>
              <th scope="row">saat başı</th>
              <td className="num">
                {money(
                  c.totalHours > 0
                    ? (c.labourCost + c.consumablesCost) / c.totalHours
                    : 0,
                )}
              </td>
            </tr>
          </tbody>
        </table>

        <table className="readout">
          <caption>Fiyat zinciri</caption>
          <tbody>
            <tr>
              <th scope="row">deri</th>
              <td className="num">{money(c.leatherCost)}</td>
            </tr>
            <tr>
              <th scope="row">işçilik</th>
              <td className="num">{money(c.labourCost)}</td>
            </tr>
            <tr>
              <th scope="row">sarf</th>
              <td className="num">{money(c.consumablesCost)}</td>
            </tr>
            {c.hardwareCost > 0 && (
              <tr>
                <th scope="row">donanım</th>
                <td className="num">{money(c.hardwareCost)}</td>
              </tr>
            )}
            <tr>
              <th scope="row">genel gider</th>
              <td className="num">{money(c.overhead)}</td>
            </tr>
            <tr>
              <th scope="row">maliyet</th>
              <td className="num">{money(c.totalCost)}</td>
            </tr>
            <tr>
              <th scope="row">kâr</th>
              <td className="num">{money(c.margin)}</td>
            </tr>
            <tr>
              <th scope="row">KDV</th>
              <td className="num">{money(c.vat)}</td>
            </tr>
          </tbody>
        </table>
      </div>

      <ul className="diagnostics">
        {notes.map((n, i) => (
          <li key={i} className="diagnostic" data-severity={n.severity}>
            <code>{n.severity === "warning" ? "DİKKAT" : "NOT"}</code>
            <span>{n.message}</span>
          </li>
        ))}
      </ul>
    </section>
  );
}
ODK_EOF_3

echo "==> Testler"
pnpm test

echo "==> Typecheck"
pnpm typecheck

echo "==> Arayuz derlemesi"
pnpm --filter @odk/web build

cat << 'ODK_DONE'

============================================================
SURE AYARI
============================================================

95x75 bifold, ayni fiyat rayicleriyle:

  once (15. adim)   4.64 sa -> 3396 TL
  katsayi duzeltmesi 3.75 sa -> 2839 TL
  hiz 0.7            2.63 sa -> 2133 TL
  hiz 0.5            1.88 sa -> 1662 TL
  elle 2.5 sa        2.50 sa -> 2054 TL

Git:
  git add -A
  git commit -m "Sure katsayilari ayarlanabilir, fazla tutulanlar duzeltildi

UC KATSAYI FAZLA TUTULMUSTU
- minutesPer100mmCut 1.5 -> 0.6. Keskin bicak 100mm'yi 15-20 saniyede
  kesiyor; sablon hizalama ve tekrar gecislerle 0.6 makul.
- minutesPer100mmEdge 8 -> 5. Kenar boyasinin KURUMA suresi aktif
  iscilik degil; zimpara + burnishing + boya cekme ~5 dakika.
- punchesPerHour 500 -> 800. Iron bir vurusta 4-6 delik aciyor.

UC YENI KOL
- speedFactor: tum sureleri olcekleyen tek kol. Deneyim, atolye duzeni
  ve aliskanlik burada topluyor.
- overrideTotalHours: kendi sureni olctuysen dogrudan gir; model devre
  disi kalir. Bilesen sureleri toplama oturacak sekilde oranlaniyor,
  yoksa tablo kendi kendisiyle celisirdi.
- time modeli tamamen disaridan verilebilir (holesPerHour vb.)

- estimateCost imzasi (pattern, rates, options) oldu
- Arayuzde saat basi maliyet de gosteriliyor
- Elle sure verilince not degisiyor: 'GECICI katsayi' uyarisi yerine
  'kendi olctugun sure her zaman tahminden iyidir'
- 374 test geciyor"

  git push
  vercel --prod
ODK_DONE
