import type { Mm } from "@odk/geometry";
import { CARD_ID1 } from "@odk/geometry";
import { CARD_THICKNESS } from "./material.js";

/**
 * KART YUVASI GEOMETRİSİ
 *
 * Bu dosyadaki en önemli bulgu: kart yuvasının YAPIM BİÇİMİ, yığın
 * kalınlığını kart sayısından daha çok etkiliyor. İki yöntem var ve
 * matematikleri tamamen farklı.
 */

/**
 * Yuva yapım biçimi.
 *
 * BELGELENMİŞ (MAKESUPPLY, Borderland Leather):
 *
 * - "stacked": her yuva düz bir dikdörtgen parça. Yuvalar üst üste
 *   bindiğinde her biri o bölgeye fazladan bir katman ekler. Sonuç hem
 *   kalın hem DENGESİZ bir kenar; ayrıca en alttaki yuvaya kart sokmak
 *   zorlaşır.
 *
 * - "t-slot": parça "T" şeklinde kesilir; yuvanın içindeki deri
 *   bölmenin kenarına kadar UZANMAZ. Bu yüzden kenarda kaç yuva olursa
 *   olsun tek katman geçer ve kenar kalınlığı sabit kalır.
 *   Pratikte en alt yuva hariç hepsi T-slot yapılır; en alttaki, dibi
 *   kapatmak için düz dikdörtgen kalır.
 *
 * Bu ayrım kural motoru için kritik: 6 yuvalı bir cüzdan "stacked" ile
 * fiziksel olarak imkânsız kalınlığa çıkarken "t-slot" ile ince kalır.
 */
export type SlotConstruction = "stacked" | "t-slot";

export type CardOrientation = "horizontal" | "vertical";

/**
 * BELGELENMİŞ (Borderland Leather): bitmiş bölme genişliği yatay kart
 * yuvası için ~100mm, dikey için ~70mm olmalı.
 *
 * Kart 85.6 × 53.98mm olduğuna göre bu, yatayda 14.4mm, dikeyde 16mm
 * toplam fazlalık demek. Fazlalık iki şeyi karşılıyor: iki yandaki
 * dikiş hatları ve kartın rahat ama gevşek olmayacak şekilde girip
 * çıkması için boşluk.
 */
export const DOCUMENTED_COMPARTMENT_WIDTH: Record<CardOrientation, Mm> = {
  horizontal: 100,
  vertical: 70,
};

/**
 * Kartın rahat girip çıkması için yuva içinde bırakılan toplam boşluk.
 *
 * Belgelenmiş bölme genişliklerinden geri hesaplandı (iki yanda 3.5mm
 * dikiş payı varsayımıyla):
 *   yatay:  100 − 85.60 − 7 = 7.4mm
 *   dikey:   70 − 53.98 − 7 = 9.0mm
 *
 * DİKKAT: değer yöne göre FARKLI. Başlangıçta tek bir sabit (7mm)
 * kullanmıştım; dikey yuvada belgelenmiş 70mm'den 2mm sapıyordu.
 * Kaynaklar iki yön için ayrı ayrı değer verdiğine göre sabiti tek
 * sayıya indirgemek veriyi bozmak olur. Sapmanın fiziksel gerekçesini
 * uydurmuyoruz; ölçülen pratik bu.
 */
export const CARD_SLIDING_CLEARANCE: Record<CardOrientation, Mm> = {
  horizontal: 7.4,
  vertical: 9.0,
};

/**
 * ⚠️ GEÇİCİ: kademe (reveal) yüksekliği.
 *
 * Üst üste binen yuvalarda her yuvanın ağzının bir alttakinden ne kadar
 * yukarıda durduğu. Aranan kaynaklarda tek bir yerleşik değer
 * bulunamadı; belgelenen tek sayı basit bir üç panelli kartlıkta
 * "üst katman 5mm daha kısa" şeklindeydi ki bu kademenin ALT SINIRI.
 *
 * Çok yuvalı cüzdanlarda kademe daha büyük olmak zorunda, yoksa alttaki
 * kartlar görünmez ve parmakla ayırmak imkânsızlaşır. 12mm makul bir
 * başlangıç ama Faz 6'da fiziksel olarak doğrulanacak.
 */
export const PROVISIONAL_SLOT_REVEAL: Mm = 12;

/** BELGELENMİŞ: kademe için mutlak alt sınır. */
export const MIN_SLOT_REVEAL: Mm = 5;

/**
 * BELGELENMİŞ (Borderland Leather): T-slot'lar birbirinin üzerine
 * oturduğu ve alttaki cebin etrafında hafifçe kıvrıldığı için iki yana
 * 2–5mm fazladan pay bırakıp sonunda fazlalığı kesmek iyi pratik.
 *
 * Bu, kesit çözücüdeki kıvrım payının küçük ölçekli versiyonu: bir
 * katman diğerinin etrafını sardığı için daha uzun olmak zorunda.
 */
export const T_SLOT_WRAP_ALLOWANCE: Mm = 3;

export interface CardSlotSpec {
  readonly count: number;
  readonly construction: SlotConstruction;
  readonly orientation: CardOrientation;
  /** Yuva derisinin kalınlığı. */
  readonly leatherThickness: Mm;
  readonly reveal?: Mm;
  readonly stitchMargin?: Mm;
}

export interface CardSlotGeometry {
  /** Bölmenin dış genişliği (dikiş payları dahil). */
  readonly compartmentWidth: Mm;
  /** Yuva yığınının toplam yüksekliği. */
  readonly stackHeight: Mm;
  /** Kenarda oluşan deri kalınlığı — T-slot'ta yuva sayısından bağımsız. */
  readonly edgeThickness: Mm;
  /** Yuvaların bindiği merkez bölgede oluşan deri kalınlığı. */
  readonly centerThickness: Mm;
  /** Kartlar takılıyken merkez bölgeye eklenen kalınlık. */
  readonly loadedThickness: Mm;
  /** Kaç parça T-slot, kaç parça düz dikdörtgen. */
  readonly tSlotPieces: number;
  readonly rectanglePieces: number;
}

function cardWidth(o: CardOrientation): Mm {
  return o === "horizontal" ? CARD_ID1.width : CARD_ID1.height;
}

function cardHeight(o: CardOrientation): Mm {
  return o === "horizontal" ? CARD_ID1.height : CARD_ID1.width;
}

export function cardSlotGeometry(spec: CardSlotSpec): CardSlotGeometry {
  const reveal = spec.reveal ?? PROVISIONAL_SLOT_REVEAL;
  const stitchMargin = spec.stitchMargin ?? 3.5;
  const n = Math.max(0, Math.floor(spec.count));
  const t = spec.leatherThickness;

  const compartmentWidth =
    cardWidth(spec.orientation) +
    CARD_SLIDING_CLEARANCE[spec.orientation] +
    2 * stitchMargin;

  // İlk yuva tam kart yüksekliği kadar yer kaplar, her ek yuva bir kademe.
  const stackHeight = n === 0 ? 0 : cardHeight(spec.orientation) + (n - 1) * reveal;

  const tSlotPieces = spec.construction === "t-slot" ? Math.max(0, n - 1) : 0;
  const rectanglePieces = n - tSlotPieces;

  // Kenar kalınlığı: T-slot'ta yuva derisi kenara uzanmadığı için sadece
  // dibi kapatan dikdörtgen geçer.
  const edgeThickness =
    spec.construction === "t-slot" ? (n > 0 ? t : 0) : n * t;

  const centerThickness = n * t;
  const loadedThickness = centerThickness + n * CARD_THICKNESS;

  return {
    compartmentWidth,
    stackHeight,
    edgeThickness,
    centerThickness,
    loadedThickness,
    tSlotPieces,
    rectanglePieces,
  };
}

export interface SlotDiagnostic {
  readonly severity: "error" | "warning";
  readonly code: string;
  readonly message: string;
}

/**
 * Yuva yapılandırmasını denetler.
 *
 * Kural motorunun kart yuvası bölümü. Amaç, geometrik olarak
 * hesaplanabilir ama fiziksel olarak kullanılamaz yapılandırmaları
 * kullanıcıya kalıp basılmadan önce bildirmek.
 */
export function validateCardSlots(spec: CardSlotSpec): SlotDiagnostic[] {
  const out: SlotDiagnostic[] = [];
  const reveal = spec.reveal ?? PROVISIONAL_SLOT_REVEAL;
  const geo = cardSlotGeometry(spec);

  if (spec.count < 1) {
    out.push({
      severity: "error",
      code: "NO_SLOTS",
      message: "Yuva sayısı en az 1 olmalı.",
    });
  }

  if (reveal < MIN_SLOT_REVEAL) {
    out.push({
      severity: "error",
      code: "REVEAL_TOO_SMALL",
      message:
        `Kademe ${reveal}mm — belgelenmiş alt sınır ${MIN_SLOT_REVEAL}mm. ` +
        `Daha azında alttaki kartlar görünmez ve parmakla ayrılamaz.`,
    });
  }

  if (spec.construction === "stacked" && spec.count > 3) {
    out.push({
      severity: "warning",
      code: "STACKED_TOO_MANY",
      message:
        `${spec.count} yuva "stacked" yapımla kenarda ${geo.edgeThickness.toFixed(1)}mm ` +
        `deri demek ve kenar dengesiz olur. T-slot yapıma geçmek ` +
        `kenar kalınlığını ${spec.leatherThickness.toFixed(1)}mm'de sabit tutar.`,
    });
  }

  if (spec.leatherThickness > 0.8) {
    out.push({
      severity: "warning",
      code: "SLOT_LEATHER_THICK",
      message:
        `Yuva derisi ${spec.leatherThickness.toFixed(1)}mm — önerilen aralık ` +
        `0.6–0.8mm. Kalın deri yuvanın esnemesini engeller ve ürün şişer.`,
    });
  }

  return out;
}

/**
 * Belgelenmiş bölme genişliğiyle karşılaştırma.
 *
 * Kendi hesabımızın sektör pratiğinden sapmasını ölçer. Sapma 3mm'yi
 * geçiyorsa ya boşluk sabitimiz ya dikiş payımız yanlış.
 */
export function compartmentWidthDeviation(
  orientation: CardOrientation,
  stitchMargin: Mm = 3.5,
): Mm {
  const computed =
    cardWidth(orientation) + CARD_SLIDING_CLEARANCE[orientation] + 2 * stitchMargin;
  return computed - DOCUMENTED_COMPARTMENT_WIDTH[orientation];
}
