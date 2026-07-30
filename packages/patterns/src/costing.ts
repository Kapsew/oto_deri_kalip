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
