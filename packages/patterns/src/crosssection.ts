import type { Mm } from "@odk/geometry";
import { EPS } from "@odk/geometry";
import type { LeatherSpec } from "./material.js";

/**
 * KESİT ÇÖZÜCÜ — motorun kalbi.
 *
 * ═══════════════════════════════════════════════════════════════════════
 * TEMEL FİKİR
 * ═══════════════════════════════════════════════════════════════════════
 *
 * Bir cüzdanı katladığında dış katman iç katmandan daha uzun bir yol
 * kateder. Kalıbı düz keserken bu farkı önceden eklemek zorundasın,
 * yoksa katlarken ürün kilitlenir.
 *
 * Fark iki bileşenden gelir:
 *
 *   1) KATMAN ÖTELEME (baskın terim)
 *      Kıvrım merkezinden d kadar uzaktaki bir katman, θ açılı kıvrımda
 *      θ·d kadar fazla yol yürür. 180°'lik bir katta (θ = π) 4mm'lik bir
 *      yığının dış katmanı iç katmandan π × 4 ≈ 12.6mm uzun olmalıdır.
 *
 *      DOĞRULAMA: MAKESUPPLY'in bifold kuralı "dış kabuk iç kabuktan
 *      yarım inç uzun olmalı" diyor (iç 8.5″ ise dış 9″). Yarım inç =
 *      12.7mm. Yani zanaatkârın deneyimle bulduğu sayı, 4mm yığın
 *      kalınlığı için fiziğin verdiği sayıyla 0.1mm içinde örtüşüyor.
 *      Bu, modelin doğru terimi yakaladığının bağımsız kanıtı.
 *
 *   2) KATMAN İÇİ GERİLME (ikincil terim)
 *      Katmanın kendi kalınlığı içinde nötr eksen tam ortada değil,
 *      iç yüzeye doğru kayar. Sac metaldeki k-faktörü budur.
 *      1.2mm deride 180° katta k'nın 0.38↔0.45 aralığındaki belirsizliği
 *      sadece ~0.26mm etki yapar — el kesim hata payımızın altında.
 *
 * Bu yüzden model her katmanın nötr ekseni boyunca yürür:
 *
 *   R_i = innerRadius + (i'den içteki katmanların toplam kalınlığı)
 *                     + k_i · t_i
 *   kıvrım payı_i = θ · R_i
 *
 * ═══════════════════════════════════════════════════════════════════════
 * NEDEN "GENİŞLİK/YÜKSEKLİK" DEĞİL DE "KESİT"
 * ═══════════════════════════════════════════════════════════════════════
 *
 * Girdi ürünün dış ölçüsü değil, katman yığınının kendisi. Yeni bir model
 * (farklı kart sayısı, para bölmesi, bozuk para gözü) yeni bir çizim
 * değil, yeni bir yığın dizilimi. Kalıp otomatik düşer.
 */

/** Kesitteki bir katman. */
export interface Layer {
  readonly id: string;
  readonly name: string;
  readonly spec: LeatherSpec;
}

/**
 * Bir kıvrım.
 *
 * `stack` katman id'lerini kıvrımın İÇİNDEN DIŞINA doğru sıralar.
 * Sıra kritik: yanlış sıra, yanlış öteleme mesafesi demek.
 */
export interface Fold {
  readonly id: string;
  readonly name: string;
  /** Kıvrım açısı, derece. 180 = tam kat (bifold sırtı). */
  readonly angleDeg: number;
  /** En iç katmanın İÇ yüzeyindeki yarıçap. */
  readonly innerRadius: Mm;
  /** Katman id'leri, içten dışa. */
  readonly stack: readonly string[];
  /**
   * Katman OLMAYAN dolgu: id'si verilen katmanın hemen İÇİNE eklenen
   * kalınlık (mm).
   *
   * NİYE GEREKLİ: bifold'da dış kabuk, iç kabuğun etrafını değil
   * TÜM İÇERİĞİN etrafını dolanır — kart yığını, kartların kendisi,
   * banknot. Bu içerik kıvrımdan geçen bir deri katmanı değil, ama dış
   * kabuğun yürüyeceği yarıçapı belirliyor.
   *
   * Bu alan olmadan modelin verdiği dış/iç fark 2.8mm çıkıyordu;
   * belgelenmiş yarım inç kuralı 12.7mm diyor. Aradaki farkın tamamı
   * bu dolgudan geliyor.
   */
  readonly gaps?: Readonly<Record<string, Mm>>;
}

/** Düz bir bölüm (kıvrım olmayan kısım). */
export interface Run {
  readonly id: string;
  readonly name: string;
  readonly length: Mm;
  /** Bu bölümden geçen katman id'leri. Sıra önemsiz. */
  readonly layers: readonly string[];
}

export interface CrossSection {
  readonly name: string;
  readonly layers: readonly Layer[];
  readonly runs: readonly Run[];
  readonly folds: readonly Fold[];
}

// --- Sonuç ----------------------------------------------------------------

export interface LayerResult {
  readonly layerId: string;
  readonly name: string;
  /** Düz bölümlerden gelen toplam. */
  readonly straightLength: Mm;
  /** Kıvrımlardan gelen toplam (nötr eksen yay uzunlukları). */
  readonly bendAllowance: Mm;
  /** Kalıba çizilecek düz uzunluk. */
  readonly flatLength: Mm;
}

export interface FoldResult {
  readonly foldId: string;
  readonly name: string;
  /** Kıvrımdaki katmanların toplam kalınlığı. */
  readonly stackThickness: Mm;
  /** En dış ve en iç katmanın kıvrım payı farkı. */
  readonly outerInnerDelta: Mm;
}

export interface Diagnostic {
  readonly severity: "error" | "warning";
  readonly code: string;
  readonly message: string;
}

export interface CrossSectionResult {
  readonly layers: readonly LayerResult[];
  readonly folds: readonly FoldResult[];
  readonly diagnostics: readonly Diagnostic[];
}

// --- Çekirdek hesap -------------------------------------------------------

export function degToRad(deg: number): number {
  return (deg * Math.PI) / 180;
}

/**
 * İki katman arasındaki uzunluk farkının saf geometrik çekirdeği.
 *
 * θ açılı bir kıvrımda, birbirinden `gap` kadar uzaktaki iki katmanın
 * kat ettiği yol farkı θ·gap'tır. Modelin en önemli tek formülü;
 * yarım inç kuralını üreten şey bu.
 */
export function foldLengthDelta(gap: Mm, angleDeg: number): Mm {
  return degToRad(angleDeg) * gap;
}

/**
 * Bir yığını saran kıvrımın doğal iç yarıçapı.
 *
 * Deri kendi etrafına sıfır yarıçapla katlanamaz; sardığı yığının
 * yarısı kadar bir yarıçap oluşur. Kullanıcı daha küçük bir değer
 * verirse uyarı üretilir.
 */
export function naturalInnerRadius(wrappedThickness: Mm): Mm {
  return wrappedThickness / 2;
}

/** Katman id'sinden katmana hızlı erişim. */
function indexLayers(layers: readonly Layer[]): Map<string, Layer> {
  const map = new Map<string, Layer>();
  for (const l of layers) map.set(l.id, l);
  return map;
}

export function stackThickness(
  fold: Fold,
  index: Map<string, Layer>,
): Mm {
  let total = 0;
  for (const id of fold.stack) {
    total += fold.gaps?.[id] ?? 0;
    const l = index.get(id);
    if (l !== undefined) total += l.spec.thickness;
  }
  return total;
}

/**
 * Kesiti çözer: her katman için düz uzunluk.
 *
 * Girdi hatalarını sessizce yutmaz — eksik katman referansı, geçersiz
 * açı, fiziksel olarak imkânsız yarıçap hepsi tanılama olarak döner.
 * `error` seviyesindeki tanılama varsa çıkan ölçülere güvenilmemeli.
 */
export function solveCrossSection(cs: CrossSection): CrossSectionResult {
  const index = indexLayers(cs.layers);
  const diagnostics: Diagnostic[] = [...validate(cs, index)];

  const straight = new Map<string, Mm>();
  const bend = new Map<string, Mm>();
  for (const l of cs.layers) {
    straight.set(l.id, 0);
    bend.set(l.id, 0);
  }

  for (const run of cs.runs) {
    for (const id of run.layers) {
      const cur = straight.get(id);
      if (cur !== undefined) straight.set(id, cur + run.length);
    }
  }

  const foldResults: FoldResult[] = [];

  for (const fold of cs.folds) {
    const theta = degToRad(fold.angleDeg);
    let insideThickness = 0;
    let innermostArc: Mm | undefined;
    let outermostArc: Mm | undefined;

    for (const id of fold.stack) {
      const layer = index.get(id);
      if (layer === undefined) continue;

      // Bu katmandan önce gelen, katman olmayan dolgu.
      insideThickness += fold.gaps?.[id] ?? 0;

      const t = layer.spec.thickness;
      const neutralRadius =
        fold.innerRadius + insideThickness + layer.spec.kFactor * t;
      const arc = theta * neutralRadius;

      const cur = bend.get(id);
      if (cur !== undefined) bend.set(id, cur + arc);

      if (innermostArc === undefined) innermostArc = arc;
      outermostArc = arc;

      insideThickness += t;
    }

    foldResults.push({
      foldId: fold.id,
      name: fold.name,
      stackThickness: insideThickness,
      outerInnerDelta:
        outermostArc !== undefined && innermostArc !== undefined
          ? outermostArc - innermostArc
          : 0,
    });
  }

  const layerResults: LayerResult[] = cs.layers.map((l) => {
    const s = straight.get(l.id) ?? 0;
    const b = bend.get(l.id) ?? 0;
    return {
      layerId: l.id,
      name: l.name,
      straightLength: s,
      bendAllowance: b,
      flatLength: s + b,
    };
  });

  return { layers: layerResults, folds: foldResults, diagnostics };
}

// --- Doğrulama -----------------------------------------------------------

function validate(
  cs: CrossSection,
  index: Map<string, Layer>,
): Diagnostic[] {
  const out: Diagnostic[] = [];

  if (index.size !== cs.layers.length) {
    out.push({
      severity: "error",
      code: "DUPLICATE_LAYER_ID",
      message: "Aynı id'ye sahip birden fazla katman var.",
    });
  }

  for (const l of cs.layers) {
    if (l.spec.thickness <= EPS) {
      out.push({
        severity: "error",
        code: "ZERO_THICKNESS",
        message: `"${l.name}" katmanının kalınlığı sıfır ya da negatif.`,
      });
    }
    if (l.spec.kFactor < 0 || l.spec.kFactor > 1) {
      out.push({
        severity: "error",
        code: "K_OUT_OF_RANGE",
        message: `"${l.name}" için k-faktörü 0–1 dışında (${l.spec.kFactor}).`,
      });
    }
  }

  for (const run of cs.runs) {
    if (run.length <= EPS) {
      out.push({
        severity: "error",
        code: "ZERO_RUN",
        message: `"${run.name}" bölümünün uzunluğu sıfır ya da negatif.`,
      });
    }
    for (const id of run.layers) {
      if (!index.has(id)) {
        out.push({
          severity: "error",
          code: "UNKNOWN_LAYER_REF",
          message: `"${run.name}" bölümü tanımsız katmana atıf yapıyor: ${id}`,
        });
      }
    }
  }

  for (const fold of cs.folds) {
    if (fold.angleDeg <= 0 || fold.angleDeg > 360) {
      out.push({
        severity: "error",
        code: "BAD_ANGLE",
        message: `"${fold.name}" kıvrım açısı geçersiz (${fold.angleDeg}°).`,
      });
    }
    if (fold.innerRadius < 0) {
      out.push({
        severity: "error",
        code: "NEGATIVE_RADIUS",
        message: `"${fold.name}" iç yarıçapı negatif.`,
      });
    }
    if (fold.stack.length === 0) {
      out.push({
        severity: "error",
        code: "EMPTY_FOLD_STACK",
        message: `"${fold.name}" kıvrımında hiç katman yok.`,
      });
    }

    for (const id of Object.keys(fold.gaps ?? {})) {
      if (!fold.stack.includes(id)) {
        out.push({
          severity: "error",
          code: "GAP_NOT_IN_STACK",
          message: `"${fold.name}" kıvrımında dolgu tanımsız katmana atıf yapıyor: ${id}`,
        });
      }
      const g = fold.gaps?.[id];
      if (g !== undefined && g < 0) {
        out.push({
          severity: "error",
          code: "NEGATIVE_GAP",
          message: `"${fold.name}" kıvrımında "${id}" için negatif dolgu.`,
        });
      }
    }

    const seen = new Set<string>();
    for (const id of fold.stack) {
      if (!index.has(id)) {
        out.push({
          severity: "error",
          code: "UNKNOWN_LAYER_REF",
          message: `"${fold.name}" kıvrımı tanımsız katmana atıf yapıyor: ${id}`,
        });
      }
      if (seen.has(id)) {
        out.push({
          severity: "error",
          code: "DUPLICATE_IN_STACK",
          message: `"${fold.name}" kıvrımında "${id}" iki kez geçiyor.`,
        });
      }
      seen.add(id);
    }

    // Fiziksel makullük: deri KENDİ kalınlığından daha keskin kıvrılamaz.
    //
    // Ölçüt bilerek EN İÇ KATMANIN kalınlığı, tüm yığın değil. İlk
    // sürümde yığın kalınlığına bakılıyordu ve bifold'da her zaman
    // yanlış uyarı veriyordu: dolgulu bir kıvrımda en iç katman kendi
    // etrafına sarılır (yarıçap ~0.4mm), dış katman ise tüm içeriğin
    // etrafını dolanır. İkisinin yarıçapı doğal olarak çok farklı ve
    // "innerRadius" tanımı gereği yalnızca en içtekini tarif eder.
    const innermostId = fold.stack[0];
    const innermost =
      innermostId === undefined ? undefined : index.get(innermostId);
    if (innermost !== undefined) {
      const minRadius = innermost.spec.thickness * 0.5;
      if (fold.innerRadius + EPS < minRadius) {
        out.push({
          severity: "warning",
          code: "TIGHT_RADIUS",
          message:
            `"${fold.name}" iç yarıçapı (${fold.innerRadius.toFixed(2)}mm) ` +
            `en iç katmanın kalınlığına göre çok keskin ` +
            `(en az ~${minRadius.toFixed(2)}mm olmalı). ` +
            `Deri bu yarıçapta kırılır ve kalıp kısa çıkar.`,
        });
      }
    }
  }

  return out;
}

export function hasErrors(result: CrossSectionResult): boolean {
  return result.diagnostics.some((d) => d.severity === "error");
}

/** Belirli bir katmanın sonucunu getirir. */
export function layerResult(
  result: CrossSectionResult,
  layerId: string,
): LayerResult | undefined {
  return result.layers.find((l) => l.layerId === layerId);
}
