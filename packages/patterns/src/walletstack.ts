import type { Mm } from "@odk/geometry";
import type { Diagnostic } from "./crosssection.js";
import type { SlotConstruction } from "./cardslot.js";
import { cardSlotGeometry } from "./cardslot.js";
import type { Currency } from "./banknote.js";
import { billPocketGeometry } from "./banknote.js";
import type { Temper } from "./material.js";
import {
  BIFOLD_TARGET_CLOSED_THICKNESS,
  CARD_THICKNESS,
  MAX_CLOSED_THICKNESS,
} from "./material.js";
import type { BifoldParams } from "./bifold.js";
import type { PatternResult } from "./cardholder.js";
import type { NormPoint, SlotShapeId } from "./slotshape.js";
import { BIFOLD_DEFAULTS, generateBifold } from "./bifold.js";

/**
 * MODÜL YIĞINI — "kendi kalıbını kur" katmanı
 *
 * ═══════════════════════════════════════════════════════════════════════
 * NEDEN AYRI BİR KATMAN, NEDEN MOTORU YENİDEN YAZMIYORUZ
 * ═══════════════════════════════════════════════════════════════════════
 *
 * Kural 3: kalıp bir "şekil" değil, bir kesit çözümüdür. `generateBifold`
 * bu çözümü zaten üretiyor ve üç doğrulama çapası (yarım inç kuralı,
 * bölme genişliği, açık ölçü) ona sabitlenmiş durumda. Bu katman o
 * çözücüyü DEĞİŞTİRMEZ; kullanıcının modül modül kurduğu bir yığını
 * kanıtlanmış çözücünün girdisine DERLER.
 *
 * Böylece iki şey birden doğru kalır:
 *   1. Çapalar yeşil kalır — çünkü aynı `BifoldParams` çözücüye gidiyor.
 *   2. Kullanıcı gerçekten modül kompoze ediyor — yığın birinci sınıf bir
 *      veri; her modülün kalınlık/yükseklik katkısı bildiriliyor ve kural
 *      motoru bunları kompozisyon anında denetliyor.
 *
 * MVP kapsamı (bilinçli sınırlar):
 *   • İskelet SABİT: bifold. (Faz 3'te kartlık/çanta da bu modele geçer.)
 *   • Paneller SİMETRİK: çözücü panel başına tek yuva sayısı alıyor;
 *     yığın iki panele de uygulanır. Asimetrik panel çözücü değişikliği
 *     ister; buraya temiz genişleme noktası bırakıldı ama v1'de yok.
 *   • Yuvalar YATAY. Banknot bölmesi bifold'un doğası gereği hep var.
 */

/** Kullanıcının panele eklediği tek kart yuvası modülü. */
export interface CardSlotModule {
  readonly kind: "cardSlot";
}

/** Cüzdanın sırtındaki banknot bölmesi. Bifold'da tekildir ve zorunludur. */
export interface BillPocketModule {
  readonly kind: "billPocket";
  readonly currency: Currency;
}

export type WalletModule = CardSlotModule | BillPocketModule;

export function cardSlotModule(): CardSlotModule {
  return { kind: "cardSlot" };
}

export function billPocketModule(currency: Currency): BillPocketModule {
  return { kind: "billPocket", currency };
}

/**
 * Yığının tümüne uygulanan paylaşımlı ayarlar.
 *
 * Kademe ve yapım biçimi tek tek modülde DEĞİL burada tutuluyor: çözücü
 * tüm yuvalara tek bir `construction` ve tek bir `reveal` uyguluyor.
 * Modülün kimliği yığındaki KONUMUNDAN geliyor (taban = düz dikdörtgen,
 * üstü = T-slot) — tam olarak çözücünün yaptığı gibi.
 */
export interface WalletStackSettings {
  readonly construction: SlotConstruction;
  readonly reveal: Mm;
  readonly outerThickness: Mm;
  readonly innerThickness: Mm;
  readonly slotThickness: Mm;
  readonly temper: Temper;
  readonly stitchMargin: Mm;
  readonly cornerRadius: Mm;
  readonly penAllowance: Mm;
  readonly pitch?: Mm;
  /** Üst yuvaların ağız şekli. Verilmezse t-slot (düz ağız). */
  readonly slotShape?: SlotShapeId;
  /** Kullanıcının çizdiği ağız profili. Verilirse slotShape yerine geçer. */
  readonly customMouth?: readonly NormPoint[] | undefined;
}

/**
 * Kullanıcının kurduğu modül yığını.
 * `slots`: panel başına, alttan üste sıralı kart yuvaları.
 * `spine`: banknot bölmesi (tekil).
 */
export interface WalletStack {
  readonly slots: readonly CardSlotModule[];
  readonly spine: BillPocketModule;
  readonly settings: WalletStackSettings;
}

/**
 * Üst sınır: bifold panel başına yuva sayısı. Çözücü 8'e kadar test
 * edilmiş; ötesi hem A4'e sığmaz hem fiziksel olarak anlamsız kalınlaşır.
 */
export const MAX_PANEL_SLOTS = 8;

/**
 * Varsayılan yığın, `BIFOLD_DEFAULTS` ile BİREBİR aynı yapılandırmaya
 * derlensin diye türetildi. Yani boş builder = mevcut varsayılan bifold.
 * Çapaların yığın yolundan da geçtiğini test bununla doğruluyor.
 */
export const WALLET_STACK_DEFAULTS: WalletStack = {
  slots: [cardSlotModule(), cardSlotModule(), cardSlotModule()],
  spine: billPocketModule("TRY"),
  settings: {
    construction: BIFOLD_DEFAULTS.construction,
    reveal: BIFOLD_DEFAULTS.reveal,
    outerThickness: BIFOLD_DEFAULTS.outerThickness,
    innerThickness: BIFOLD_DEFAULTS.innerThickness,
    slotThickness: BIFOLD_DEFAULTS.slotThickness,
    temper: BIFOLD_DEFAULTS.temper,
    stitchMargin: BIFOLD_DEFAULTS.stitchMargin,
    cornerRadius: BIFOLD_DEFAULTS.cornerRadius,
    penAllowance: BIFOLD_DEFAULTS.penAllowance,
    ...(BIFOLD_DEFAULTS.pitch === undefined ? {} : { pitch: BIFOLD_DEFAULTS.pitch }),
  },
};

/** Yığını, tam olarak `count` kart yuvası olacak şekilde döndürür (0..MAX). */
export function withSlotCount(stack: WalletStack, count: number): WalletStack {
  const n = Math.max(0, Math.min(MAX_PANEL_SLOTS, Math.floor(count)));
  const slots: CardSlotModule[] = [];
  for (let i = 0; i < n; i++) slots.push(cardSlotModule());
  return { ...stack, slots };
}

/** Modül yığınını kanıtlanmış çözücünün girdisine DERLER. */
export function compileToBifoldParams(stack: WalletStack): BifoldParams {
  const s = stack.settings;
  return {
    cardSlotsPerSide: stack.slots.length,
    construction: s.construction,
    currency: stack.spine.currency,
    outerThickness: s.outerThickness,
    innerThickness: s.innerThickness,
    slotThickness: s.slotThickness,
    temper: s.temper,
    reveal: s.reveal,
    stitchMargin: s.stitchMargin,
    cornerRadius: s.cornerRadius,
    penAllowance: s.penAllowance,
    ...(s.pitch === undefined ? {} : { pitch: s.pitch }),
    ...(s.slotShape === undefined ? {} : { slotShape: s.slotShape }),
    ...(s.customMouth === undefined ? {} : { customMouth: s.customMouth }),
  };
}

/** Yığından tam kalıp üretir. Çözücü diagnostikleri sonucun içinde döner. */
export function generateFromStack(stack: WalletStack): PatternResult {
  return generateBifold(compileToBifoldParams(stack));
}

/** Tek bir modülün bildirdiği katkı — builder'ın canlı dökümü için. */
export interface ModuleContribution {
  readonly label: string;
  /** Boş cüzdana kattığı kalınlık (panel başına tek yüz). */
  readonly closedThickness: Mm;
  /** Kart yüklüyken kattığı kalınlık. */
  readonly loadedThickness: Mm;
  /** Panel üzerinde kapladığı dikey yükseklik. */
  readonly height: Mm;
}

/**
 * Yığının toplam katkıları. Buradaki `closedThickness` ve
 * `loadedThickness` çözücünün ürettiği özet ile BİREBİR aynı formülü
 * kullanıyor; test bu eşitliği sabitliyor. Böylece builder'da görünen
 * sayı ile üretilen kalıbın sayısı ayrışamaz.
 */
export interface StackContributions {
  readonly slotCount: number;
  readonly perPanelStackHeight: Mm;
  readonly closedThickness: Mm;
  readonly loadedThickness: Mm;
  readonly compartmentWidth: Mm;
  readonly billCompartmentWidth: Mm;
  readonly minWalletHeight: Mm;
  readonly modules: readonly ModuleContribution[];
}

export function stackContributions(stack: WalletStack): StackContributions {
  const s = stack.settings;
  const n = stack.slots.length;

  const slotGeo = cardSlotGeometry({
    count: n,
    construction: s.construction,
    orientation: "horizontal",
    leatherThickness: s.slotThickness,
    reveal: s.reveal,
    stitchMargin: s.stitchMargin,
  });
  const billGeo = billPocketGeometry({
    currency: stack.spine.currency,
    leatherThickness: s.innerThickness,
    stitchMargin: s.stitchMargin,
  });

  // Kabuk (dış + iç), her ikisi iki panelde. Çözücüyle aynı formül.
  const shellClosed = 2 * s.outerThickness + 2 * s.innerThickness;
  const centerPerPanel = slotGeo.centerThickness; // = n * slotThickness
  const closedThickness = shellClosed + 2 * centerPerPanel;
  const loadedThickness = shellClosed + 2 * (centerPerPanel + n * CARD_THICKNESS);

  // Taban yuvası tam kart yüksekliği; üsttekiler yalnızca kademe kadar.
  // Toplamları slotGeo.stackHeight'a eşit olur (invariant).
  const baseHeight = n === 0 ? 0 : slotGeo.stackHeight - (n - 1) * s.reveal;
  const modules: ModuleContribution[] = stack.slots.map((_, i) => ({
    label: i === 0 ? "Kart yuvası — taban" : `Kart yuvası ${i + 1}`,
    closedThickness: s.slotThickness,
    loadedThickness: s.slotThickness + CARD_THICKNESS,
    height: i === 0 ? baseHeight : s.reveal,
  }));
  modules.push({
    label: `Banknot bölmesi (${stack.spine.currency})`,
    // İç kabuk zaten kabuk katmanında; sırt ayrı bir kalınlık eklemiyor.
    closedThickness: 0,
    loadedThickness: 0,
    height: billGeo.minWalletHeight,
  });

  return {
    slotCount: n,
    perPanelStackHeight: slotGeo.stackHeight,
    closedThickness,
    loadedThickness,
    compartmentWidth: slotGeo.compartmentWidth,
    billCompartmentWidth: billGeo.compartmentWidth,
    minWalletHeight: billGeo.minWalletHeight,
    modules,
  };
}

/**
 * KURAL MOTORU — kompozisyon ön denetimi.
 *
 * Bu, tam geometri üretmeden çalışan HIZLI ön kontroldür; builder yazarken
 * her modül eklemede canlı geri bildirim verir. Nihai/otoriter diagnostik
 * yine çözücüden (`generateFromStack(...).diagnostics`) gelir. Aynı eşikleri
 * kullandıkları için ikisi çelişmez; kodlar `STACK_` önekiyle ayrıştı ki
 * "ön uyarı" ile "üretim sonucu" karışmasın.
 */
export function validateStack(stack: WalletStack): Diagnostic[] {
  const c = stackContributions(stack);
  const diags: Diagnostic[] = [];

  if (c.slotCount === 0) {
    diags.push({
      severity: "warning",
      code: "STACK_NO_SLOTS",
      message:
        "Yığında kart yuvası yok — bu yalnızca banknot bölmesi olan bir " +
        "cüzdan olur. Kart taşımak için en az bir yuva ekle.",
    });
  }

  if (c.loadedThickness > MAX_CLOSED_THICKNESS) {
    diags.push({
      severity: "error",
      code: "STACK_TOO_THICK",
      message:
        `Kart yüklü kalınlık ${c.loadedThickness.toFixed(1)}mm — üst sınır ` +
        `${MAX_CLOSED_THICKNESS}mm. Yuva çıkar ya da daha ince yuva derisi seç.`,
    });
  } else if (c.closedThickness > BIFOLD_TARGET_CLOSED_THICKNESS) {
    diags.push({
      severity: "warning",
      code: "STACK_BULKY",
      message:
        `Boş kalınlık ${c.closedThickness.toFixed(1)}mm — belgelenmiş hedef ` +
        `${BIFOLD_TARGET_CLOSED_THICKNESS}mm. Kart yüklü ` +
        `${c.loadedThickness.toFixed(1)}mm olacak.`,
    });
  }

  return diags;
}
