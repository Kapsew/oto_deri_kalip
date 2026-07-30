import type { Mm } from "@odk/geometry";

/**
 * Malzeme modeli.
 *
 * KAYNAK NOTU: Bu dosyadaki değerlerin bir kısmı belgelenmiş sektör
 * standardı, bir kısmı ise GEÇİCİ tahmin. İkisi ayrı ayrı işaretlendi.
 * Karıştırmak, sonradan hangi sayının güvenilir olduğunu bilememek
 * demek olur.
 */

// --- Kalınlık birimi: onsdan milimetreye -----------------------------------

/**
 * BELGELENMİŞ: 1 oz deri = 1/64 inç kalınlık.
 * 1/64 × 25.4 = 0.396875mm. Sektörde yaygın olarak "0.4mm" diye
 * yuvarlanır; biz tam değeri kullanıyoruz çünkü 8 oz'da yuvarlama
 * hatası 0.025mm birikir.
 *
 * Kaynak: yaygın tanner/tedarikçi dönüşüm tabloları (Weaver, Maverick,
 * Montana Leather vb. hepsi aynı tanımı veriyor).
 */
export const MM_PER_OZ: Mm = 25.4 / 64;

export function ozToMm(oz: number): Mm {
  return oz * MM_PER_OZ;
}

export function mmToOz(mm: Mm): number {
  return mm / MM_PER_OZ;
}

/**
 * Deri onslu aralıklarla satılır (3/4 oz gibi) çünkü doğal deri kalınlığı
 * post boyunca değişir. Aralığın ortasını almak, tek bir nominal değer
 * gereken hesaplar için makul varsayım.
 */
export function ozRangeToMm(minOz: number, maxOz: number): Mm {
  return ozToMm((minOz + maxOz) / 2);
}

// --- Deri tipi ve sertlik --------------------------------------------------

export type Temper = "veg-tan-firm" | "veg-tan-soft" | "chrome-soft";

export interface LeatherSpec {
  readonly temper: Temper;
  readonly thickness: Mm;
  /**
   * Nötr eksenin iç yüzeyden uzaklığının kalınlığa oranı.
   *
   * ⚠️ GEÇİCİ DEĞER — DERİ İÇİN ÖLÇÜLMÜŞ VERİ YOK.
   *
   * Literatür taraması sonucu: k-faktörü tabloları yalnızca sac metal
   * için mevcut (tipik aralık 0.33–0.50, iç yarıçap/kalınlık oranına ve
   * malzemeye göre değişir). Deri için eşdeğer bir yayınlanmış tablo
   * bulunamadı. Aşağıdaki değerler sac metal aralığından deri
   * davranışına göre akıl yürütmeyle seçildi:
   *
   * - Sert bitkisel sepi az sıkışır → nötr eksen merkeze yakın (0.45)
   * - Yumuşak deri iç yüzeyde daha çok sıkışır → eksen içe kayar (0.38)
   *
   * BÜYÜKLÜK KONTROLÜ: 1.2mm deride 180° katta k'yı 0.38'den 0.45'e
   * çekmek düz uzunluğu π × 1.2 × 0.07 ≈ 0.26mm değiştirir. Bu bizim
   * ±0.5mm el kesim hata payımızın altında. Yani k'yı yanlış tahmin
   * etmek kalıbı bozmaz; ASIL belirleyici terim katman öteleme mesafesi
   * (bkz. crosssection.ts). Buna güvenip k'yı ihmal etmiyoruz ama
   * Faz 6'da fiziksel kalibrasyonla düzeltilecek bir parametre olarak
   * işaretliyoruz.
   */
  readonly kFactor: number;
}

/** ⚠️ GEÇİCİ — Faz 6 fiziksel doğrulamasında kalibre edilecek. */
export const PROVISIONAL_K_FACTOR: Record<Temper, number> = {
  "veg-tan-firm": 0.45,
  "veg-tan-soft": 0.4,
  "chrome-soft": 0.38,
};

export function leather(temper: Temper, thickness: Mm): LeatherSpec {
  return { temper, thickness, kFactor: PROVISIONAL_K_FACTOR[temper] };
}

// --- Kalınlık önerileri ---------------------------------------------------

/**
 * BELGELENMİŞ (zanaat pratiği): cüzdan bileşenleri için önerilen
 * kalınlık aralıkları.
 *
 * Kaynaklar birbiriyle tutarlı:
 * - Dış kabuk 0.8–1.2mm; bifold'da alt uçta (0.8–1.0) kalmak öneriliyor
 * - Kart yuvaları 0.6–0.8mm; kart girip çıkabilmesi için esnek olmalı,
 *   kalın olursa ürün şişiyor (yeni başlayanların en sık hatası)
 * - Bölmeler yapısal yük taşımadığı için ince olabilir
 * - MAKESUPPLY kalıpları 1.2–1.4mm (3/3.5 oz) deriyle örneklenmiş;
 *   dış kabukta 4 oz üstüne çıkmamak, iç kabuk ve kart yuvalarını
 *   2/3 oz bandında tutmak öneriliyor
 */
export interface ThicknessRange {
  readonly min: Mm;
  readonly max: Mm;
  readonly preferred: Mm;
}

export const RECOMMENDED_THICKNESS: Record<
  "outerShell" | "innerShell" | "cardSlot" | "divider",
  ThicknessRange
> = {
  outerShell: { min: 0.8, max: 1.2, preferred: 1.0 },
  innerShell: { min: 0.6, max: 1.0, preferred: 0.8 },
  cardSlot: { min: 0.6, max: 0.8, preferred: 0.7 },
  divider: { min: 0.4, max: 0.7, preferred: 0.6 },
};

/**
 * BELGELENMİŞ: iyi yapılmış bir bifold boşken 6–8mm'yi geçmemeli.
 * Katmanlar kart eklenmeden bu sınırı aşıyorsa deri seçimi yeniden
 * düşünülmeli.
 */
export const BIFOLD_TARGET_CLOSED_THICKNESS: Mm = 8;

/**
 * Kural motoru üst sınırı. Bunun üstü artık cep cüzdanı değil.
 * 6–8mm hedefin üstünde tolerans bırakıyoruz çünkü kart yüklü hâli
 * hesaba katılıyor.
 */
export const MAX_CLOSED_THICKNESS: Mm = 20;

/**
 * BELGELENMİŞ (zanaat pratiği): iki veya daha fazla parçanın örtüştüğü
 * yerde kenarı tıraşlamak (skiving) hacmi belirgin şekilde azaltıyor.
 *
 * ⚠️ ORAN GEÇİCİ: tıraşlamanın kalınlığı ne kadar düşürdüğüne dair
 * sayısal veri bulunamadı. 0.5 (yarıya indirme) makul bir başlangıç;
 * Faz 6'da ölçülecek.
 */
export const PROVISIONAL_SKIVE_FACTOR = 0.5;

/** BELGELENMİŞ: ISO/IEC 7810 ID-1 kart kalınlığı. */
export const CARD_THICKNESS: Mm = 0.76;
