import type { Mm } from "@odk/geometry";

/**
 * BANKNOT VE PARA BÖLMESİ
 *
 * Cüzdanın açık genişliğini iki şey belirler: banknot genişliği ve iki
 * kart yığınının yan yana genişliği. Hangisi büyükse o kazanır.
 */

export type Currency = "TRY" | "USD" | "EUR" | "GBP";

export interface Banknote {
  readonly currency: Currency;
  readonly label: string;
  /** En büyük kupürün uzun kenarı. */
  readonly width: Mm;
  /** En büyük kupürün kısa kenarı. */
  readonly height: Mm;
  /** Bu oturumda kaynaktan doğrulandı mı? */
  readonly verified: boolean;
  readonly note: string;
}

/**
 * En büyük kupüre göre ölçüler. Cüzdan en büyük banknotu almalı,
 * ortalamayı değil.
 *
 * TCMB tüm TL banknotlarını uzun kenarda 6mm, kısa kenarda ikili grup
 * hâlinde 4mm farkla basıyor; yani en büyük kupür diğerlerini de kapsıyor.
 */
export const BANKNOTES: Record<Currency, Banknote> = {
  TRY: {
    currency: "TRY",
    label: "Türk lirası (200 TL)",
    width: 160,
    height: 72,
    verified: true,
    note: "TCMB verisi. 200 TL en büyük kupür: 160 × 72mm.",
  },
  USD: {
    currency: "USD",
    label: "ABD doları (tüm kupürler)",
    width: 156,
    height: 66.3,
    verified: true,
    note: "Tüm dolar kupürleri aynı boyutta: 156 × 66.3mm.",
  },
  EUR: {
    currency: "EUR",
    label: "Euro (200 €)",
    width: 153,
    height: 77,
    verified: false,
    note:
      "⚠ Bu oturumda kaynaktan doğrulanmadı. Europa serisi 200 € için " +
      "153 × 77mm; eski seri 200/500 € daha büyüktü (160 × 82mm). " +
      "Kullanmadan önce doğrula.",
  },
  GBP: {
    currency: "GBP",
    label: "Sterlin (£50)",
    width: 146,
    height: 77,
    verified: false,
    note:
      "⚠ Bu oturumda kaynaktan doğrulanmadı. Polimer £50 için 146 × 77mm.",
  },
};

/**
 * Banknotun bölmeye rahat girmesi için yanlardan bırakılan toplam boşluk.
 *
 * Kart yuvasındaki 7.4mm'den küçük tutuluyor: banknot ince ve esnek,
 * kart gibi rijit değil; fazla boşluk paranın bölme içinde kaymasına ve
 * kenarlarının kıvrılmasına yol açıyor.
 */
export const BILL_CLEARANCE: Mm = 4;

/**
 * Banknotun bölme ağzından yukarıda kalmaması için gereken asgari örtü.
 *
 * Banknot bölmenin ağzından taşarsa hem görünür hem yıpranır. Cüzdan
 * yüksekliği banknot yüksekliğinden en az bu kadar fazla olmalı.
 */
export const BILL_COVER_MARGIN: Mm = 6;

export interface BillPocketSpec {
  readonly currency: Currency;
  readonly leatherThickness: Mm;
  readonly stitchMargin: Mm;
  /** Verilmezse BILL_CLEARANCE. */
  readonly clearance?: Mm;
}

export interface BillPocketGeometry {
  /** Cüzdan açıkken bölmenin iç genişliği. */
  readonly interiorWidth: Mm;
  /** Bölmenin dış genişliği (dikiş payları dahil). */
  readonly compartmentWidth: Mm;
  /** Banknotun tamamen örtülmesi için gereken asgari cüzdan yüksekliği. */
  readonly minWalletHeight: Mm;
  readonly banknote: Banknote;
}

export function billPocketGeometry(spec: BillPocketSpec): BillPocketGeometry {
  const note = BANKNOTES[spec.currency];
  const clearance = spec.clearance ?? BILL_CLEARANCE;
  const interiorWidth = note.width + clearance;
  return {
    interiorWidth,
    compartmentWidth: interiorWidth + 2 * spec.stitchMargin,
    minWalletHeight: note.height + BILL_COVER_MARGIN,
    banknote: note,
  };
}

export interface BillDiagnostic {
  readonly severity: "error" | "warning";
  readonly code: string;
  readonly message: string;
}

export function validateBillPocket(
  spec: BillPocketSpec,
  walletHeight: Mm,
): BillDiagnostic[] {
  const out: BillDiagnostic[] = [];
  const geo = billPocketGeometry(spec);

  if (walletHeight < geo.minWalletHeight) {
    out.push({
      severity: "error",
      code: "BILL_STICKS_OUT",
      message:
        `Cüzdan yüksekliği ${walletHeight.toFixed(1)}mm — ` +
        `${geo.banknote.label} için en az ${geo.minWalletHeight.toFixed(1)}mm ` +
        `gerekiyor. Banknot bölmenin ağzından taşar.`,
    });
  }

  if (!geo.banknote.verified) {
    out.push({
      severity: "warning",
      code: "BANKNOTE_UNVERIFIED",
      message: `${geo.banknote.label}: ${geo.banknote.note}`,
    });
  }

  if (spec.leatherThickness > 1.0) {
    out.push({
      severity: "warning",
      code: "BILL_LEATHER_THICK",
      message:
        `İç kabuk ${spec.leatherThickness.toFixed(1)}mm — bifold'da 0.6–1.0mm ` +
        `öneriliyor. Kalın iç kabuk kapalı kalınlığı hızla büyütür.`,
    });
  }

  return out;
}
