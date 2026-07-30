import type { Mm } from "../units.js";
import { EPS, IRON_PITCHES } from "../units.js";
import type { Vec } from "../vec.js";
import type { Polyline } from "../path/path.js";
import {
  buildArcLengthTable,
  pointAtDistance,
  tangentAtDistance,
  findCorners,
  spansBetweenCorners,
} from "../path/arclength.js";
import type { ArcLengthTable, Span } from "../path/arclength.js";

/**
 * DİKİŞ DELİĞİ DAĞITICI
 *
 * ═══════════════════════════════════════════════════════════════════════
 * ÜÇ KISIT AYNI ANDA
 * ═══════════════════════════════════════════════════════════════════════
 *
 * 1) KÖŞEDE DELİK OLMAK ZORUNDA.
 *    Köşede delik yoksa iplik dönüşü bozulur ve kenar buruşur. Bu yüzden
 *    köşeler "çapa" kabul edilir ve delik dağıtımı köşeler arasında
 *    bağımsız yapılır.
 *
 * 2) ADIM SERBEST DEĞİL.
 *    Kullanıcının elindeki pricking iron sabit adımlıdır (2.7 / 3.0 /
 *    3.38 / 3.85 / 4.0 / 5.0mm). Kenarı tam bölen keyfi bir adım
 *    üretmek işe yaramaz — o takım yok.
 *
 * 3) SEGMENT UZUNLUĞU ADIMA TAM BÖLÜNMEZ.
 *    Çözüm: adımı değiştirmek yerine delik sayısını yuvarlayıp gerçek
 *    adımı L/n olarak kabul etmek. Kalan sapma delik başına dağılır.
 *
 * ═══════════════════════════════════════════════════════════════════════
 * ADIM SEÇİMİ GLOBAL YAPILIR
 * ═══════════════════════════════════════════════════════════════════════
 *
 * Her segment için ayrı ayrı "en iyi adım" seçmek yanlış olur: tek bir
 * parçada iki farklı iron kullanılamaz. Bu yüzden aday adımların her biri
 * TÜM segmentlerde denenir ve en kötü segmentteki sapmayı en küçük yapan
 * adım seçilir (minimax). Bu, kullanıcının tek takımla en tutarlı sonucu
 * almasını sağlar.
 */

export interface StitchHole {
  readonly position: Vec;
  /** İlerleme yönü. Deliğin eğimini çizmek ve normal hesaplamak için. */
  readonly tangent: Vec;
  /** Yol başından bu deliğe kadarki mesafe. */
  readonly distance: Mm;
  readonly spanIndex: number;
  /** Köşe çapası mı? Bu delikler kaydırılamaz. */
  readonly isAnchor: boolean;
}

export interface StitchSpanPlan {
  readonly index: number;
  readonly startDistance: Mm;
  readonly endDistance: Mm;
  readonly length: Mm;
  /** Bu segmentteki delik aralığı sayısı (delik sayısı = intervals + 1). */
  readonly intervals: number;
  readonly actualPitch: Mm;
  /** Nominal adımdan sapma. 0.15mm üstü gözle görülür. */
  readonly deviation: Mm;
}

export interface StitchPlan {
  readonly holes: readonly StitchHole[];
  readonly spans: readonly StitchSpanPlan[];
  /** Kullanılacak fiziksel iron adımı. */
  readonly pitch: Mm;
  readonly totalHoles: number;
  readonly maxDeviation: Mm;
  readonly warnings: readonly string[];
}

export interface StitchOptions {
  /**
   * Kullanılacak adım. Verilmezse aday listesinden minimax ile seçilir.
   */
  readonly pitch?: Mm;
  /** Adım seçimi için adaylar. */
  readonly candidatePitches?: readonly Mm[];
  /** Köşe sayılma eşiği (derece). */
  readonly cornerAngleDeg?: number;
  /** Bu sapmanın üstünde uyarı üretilir. */
  readonly deviationLimit?: Mm;
}

/** Segment için delik aralığı sayısı ve gerçek adım. */
function fitSpan(length: Mm, pitch: Mm): { intervals: number; actualPitch: Mm } {
  const intervals = Math.max(1, Math.round(length / pitch));
  return { intervals, actualPitch: length / intervals };
}

/**
 * Sapma farkının anlamsız sayıldığı bant.
 *
 * 0.05mm, baskı hassasiyetimizle ve el kesim hata payıyla aynı
 * mertebede. Bu bandın içindeki iki adım fiziksel olarak ayırt
 * edilemez, dolayısıyla aralarında sapmaya bakarak seçim yapmak
 * anlamsızdır.
 */
export const PITCH_TIE_BAND: Mm = 0.05;

/**
 * Aday adımlar arasından seçim.
 *
 * İKİ AŞAMALI, ÇÜNKÜ TEK ÖLÇÜT YETMİYOR:
 *
 * Önce en kötü segmentteki sapmayı en küçük yapan adım bulunur. Sonra
 * bu değerin PITCH_TIE_BAND kadar yakınındaki TÜM adaylar arasından
 * EN BÜYÜĞÜ seçilir.
 *
 * NEDEN: ilk sürümde yalnızca sapma minimize ediliyordu ve gerçek bir
 * çıktıda 559.2mm'lik bir çevre için 2.7mm adım seçildi — 207 delik.
 * Oysa adayların hepsi 0.01mm'nin altında sapma veriyordu; 3.85mm ile
 * 145 delik çıkıyordu. Yani algoritma ölçülemeyecek kadar küçük bir
 * "kazanç" için kullanıcıya 62 fazla delik deldiriyordu.
 *
 * Uzun kenarlarda neredeyse her adım küçük sapma verir; ölçüt
 * dejenere olur ve seçim rastgeleye döner. Bant, o durumda emeği
 * azaltan tarafa karar verir.
 */
export function selectPitch(
  spans: readonly Span[],
  candidates: readonly Mm[] = IRON_PITCHES,
): Mm {
  if (candidates.length === 0) {
    throw new Error("selectPitch: aday adım listesi boş.");
  }

  const scored = candidates.map((pitch) => {
    let worst = 0;
    for (const span of spans) {
      const { actualPitch } = fitSpan(span.length, pitch);
      worst = Math.max(worst, Math.abs(actualPitch - pitch));
    }
    return { pitch, worst };
  });

  const bestWorst = Math.min(...scored.map((s) => s.worst));
  const acceptable = scored.filter((s) => s.worst <= bestWorst + PITCH_TIE_BAND);

  return acceptable.reduce((a, b) => (b.pitch > a.pitch ? b : a)).pitch;
}

/**
 * Kapalı ya da açık bir yol üzerine dikiş deliklerini dağıtır.
 *
 * Köşe çapaları arasında eşit aralıklı yerleşim yapılır. Kapalı yolda
 * son segmentin bitiş deliği ilk segmentin başlangıç deliğiyle aynı
 * noktadır ve iki kez üretilmez.
 */
export function distributeStitches(
  poly: Polyline,
  closed: boolean,
  options: StitchOptions = {},
): StitchPlan {
  const warnings: string[] = [];
  const deviationLimit = options.deviationLimit ?? 0.15;

  const table = buildArcLengthTable(poly, closed);
  if (table.totalLength <= EPS) {
    return {
      holes: [],
      spans: [],
      pitch: options.pitch ?? (IRON_PITCHES[0] as Mm),
      totalHoles: 0,
      maxDeviation: 0,
      warnings: ["Yol uzunluğu sıfır; delik dağıtılamaz."],
    };
  }

  const corners = findCorners(table, options.cornerAngleDeg ?? 25);
  const spans = spansBetweenCorners(table, corners);

  const pitch =
    options.pitch ?? selectPitch(spans, options.candidatePitches ?? IRON_PITCHES);

  const spanPlans: StitchSpanPlan[] = [];
  const holes: StitchHole[] = [];
  let maxDeviation = 0;

  for (let s = 0; s < spans.length; s++) {
    const span = spans[s] as Span;
    const { intervals, actualPitch } = fitSpan(span.length, pitch);
    const deviation = Math.abs(actualPitch - pitch);
    maxDeviation = Math.max(maxDeviation, deviation);

    spanPlans.push({
      index: s,
      startDistance: span.startDistance,
      endDistance: span.endDistance,
      length: span.length,
      intervals,
      actualPitch,
      deviation,
    });

    if (span.length < pitch - EPS) {
      warnings.push(
        `${s + 1}. kenar (${span.length.toFixed(1)}mm) seçilen ${pitch}mm adımdan kısa; ` +
          `tek aralığa zorlandı ve gerçek adım ${actualPitch.toFixed(2)}mm oldu.`,
      );
    }
    if (deviation > deviationLimit) {
      warnings.push(
        `${s + 1}. kenarda adım sapması ${deviation.toFixed(2)}mm ` +
          `(sınır ${deviationLimit}mm). Bu kenarda delikler gözle fark edilir ölçüde kayabilir.`,
      );
    }

    // i = intervals atlanır: o nokta bir sonraki segmentin çapası.
    // Açık yolda son segmentin bitişi ayrıca eklenir.
    for (let i = 0; i < intervals; i++) {
      const d = span.startDistance + i * actualPitch;
      holes.push(makeHole(table, d, s, i === 0));
    }
  }

  if (!closed) {
    holes.push(
      makeHole(table, table.totalLength, Math.max(0, spans.length - 1), true),
    );
  }

  return {
    holes,
    spans: spanPlans,
    pitch,
    totalHoles: holes.length,
    maxDeviation,
    warnings,
  };
}

function makeHole(
  table: ArcLengthTable,
  d: Mm,
  spanIndex: number,
  isAnchor: boolean,
): StitchHole {
  return {
    position: pointAtDistance(table, d),
    tangent: tangentAtDistance(table, d),
    distance: d,
    spanIndex,
    isAnchor,
  };
}

/**
 * Kullanıcıya basılacak özet.
 *
 * Elle kesen kullanıcı delikleri pricking iron ile kendisi yürüyor;
 * yüzlerce noktayı tek tek basmak yerine "bu kenarda kaç delik" bilgisi
 * daha kullanışlı ve daha hassas. Bu fonksiyon o metni üretir.
 */
export function stitchSummary(plan: StitchPlan): string[] {
  // Köşesi yuvarlatılmış kapalı bir hatta tek segment kalır; ona
  // "1. kenar" demek yanıltıcı olur, o segment çevrenin tamamıdır.
  const singleClosed = plan.spans.length === 1;

  return plan.spans.map((s) => {
    const label = singleClosed ? "çevre" : `${s.index + 1}. kenar`;
    return (
      `${label}: ${s.length.toFixed(1)}mm, ` +
      `${s.intervals} aralık, gerçek adım ${s.actualPitch.toFixed(2)}mm` +
      (s.deviation > 0.05 ? ` (sapma ${s.deviation.toFixed(2)}mm)` : "")
    );
  });
}
