import type { Mm } from "../units.js";
import { EPS, IRON_PITCHES } from "../units.js";
import type { Polyline } from "../path/path.js";
import { bbox, signedArea } from "../path/path.js";
import {
  offsetPolygons,
  offsetSingle,
  intersection,
  difference,
} from "./clipper.js";

/**
 * Kesim ve dikiş paylarının uygulanması.
 *
 * Bu dosya, saf geometriyi hedef kitlemizin fiziksel gerçekliğine bağlar:
 * A4'e basıp ELLE kesen kullanıcı. Öteleme değerleri estetik tercih değil,
 * ölçülmüş hata kaynaklarının telafisi.
 */

/**
 * Kalem payı seçenekleri.
 *
 * Kullanıcı şablonu kartona yapıştırıp deriye çiziyor. Kalem/bıçak ucu
 * şablon kenarından dışa kaçar: kurşun kalem ~0.3mm, keçeli ~0.5mm.
 * Telafi edilmezse parça her kenardan o kadar büyük çıkar ve katmanlar
 * birbirine oturmaz.
 */
export const PEN_ALLOWANCES: readonly Mm[] = [0, 0.3, 0.5];

/**
 * Varsayılan dikiş payı: kesim kenarından 3.5mm içeride.
 *
 * 3mm altı deri yırtılma riski taşır (özellikle 1.0-1.2mm dana derisinde),
 * 4.5mm üstü gereksiz malzeme kaybı ve şişkin kenar demek. 3.5mm hobi
 * kalıplarında yaygın değer.
 */
export const DEFAULT_STITCH_MARGIN: Mm = 3.5;

export interface CutLineOptions {
  /**
   * Kalem payı (mm). Şablonun dış hattı bu kadar İÇE alınır, böylece
   * kullanıcı dışından çizdiğinde nominal ölçüye ulaşır.
   */
  readonly penAllowance?: Mm;
  /** Lazer kerf (mm). Hobici için 0; lazer kullananda kerf/2 içe alınır. */
  readonly kerf?: Mm;
}

/**
 * Nominal parça hattından basılacak kesim hattını üretir.
 *
 * Kalem payı İÇE uygulanır — sezgiye ters gelebilir. Mantık: kullanıcı
 * çizgi izinin DIŞINDAN keser, kalem ucu da dışa kaçar; ikisi birlikte
 * parçayı büyütür. Şablonu o kadar küçük basarak nominal ölçüde
 * buluşuruz.
 */
export function cutLine(
  nominal: Polyline,
  options: CutLineOptions = {},
): Polyline {
  const pen = options.penAllowance ?? 0;
  const kerf = options.kerf ?? 0;
  const inset = pen + kerf / 2;
  if (inset <= EPS) return nominal;
  return offsetSingle(nominal, -inset, { join: "miter" });
}

/**
 * Kesim hattından dikiş hattını üretir.
 *
 * Yuvarlak birleşim kullanılır: dikiş hattı köşelerde keskin dönmez,
 * çünkü iplik köşeyi yay çizerek döner. Keskin miter köşe, delik
 * dağıtıcısına gerçekte olmayan bir kırılma bildirir.
 */
export function stitchLine(
  cut: Polyline,
  margin: Mm = DEFAULT_STITCH_MARGIN,
): Polyline {
  return offsetSingle(cut, -margin, { join: "round" });
}

/**
 * İki katmanın örtüşen alanı, dikiş hattının içinde kalan kısım hariç.
 *
 * Tutkal sadece dikiş hattının DIŞINDA kalan bant üzerine sürülür;
 * içeriye taşırsa kart yuvası yapışır ve ürün çöp olur. Bu fonksiyon
 * PDF'te taranacak tutkal bandını verir.
 */
export function glueBand(
  layerA: Polyline,
  layerB: Polyline,
  stitchMargin: Mm = DEFAULT_STITCH_MARGIN,
): Polyline[] {
  const overlap = intersection([layerA], [layerB]);
  if (overlap.length === 0) return [];

  const inner = offsetPolygons(overlap, -stitchMargin, { join: "round" });
  // Örtüşme dikiş payından daha ince: tamamı tutkal bandı olur.
  if (inner.length === 0) return overlap;

  return difference(overlap, inner);
}

/**
 * Parçanın en dar yerinin genişliği.
 *
 * NASIL: parçayı adım adım içe öteler ve hangi ötelemede yok olduğunu
 * ikili aramayla bulur. Yok olma eşiği d ise en dar boyun 2d'dir
 * (öteleme her iki kenardan aynı anda gelir).
 *
 * NİYE: kural motorunun "bu parça çok ince, dikiş payı sığmaz" kontrolü
 * için. Kart yuvası ağzı ile kesim kenarı arasında 8mm bırakmayı şart
 * koştuk; bu fonksiyon o kuralı geometriden bağımsız doğrular.
 *
 * Doğruluk `tolerance` kadardır; varsayılan 0.05mm baskı hassasiyetimizle
 * aynı mertebede.
 */
export function narrowestWidth(poly: Polyline, tolerance: Mm = 0.05): Mm {
  const b = bbox(poly);
  const hiBound = Math.min(b.width, b.height) / 2 + tolerance;
  let hi = hiBound;
  let lo = 0;

  // Üst sınırda hâlâ sağlamsa (olmaması gerekir; bbox yarısı her şeyi
  // yok eder) bbox kısa kenarını döndür.
  if (isIntact(poly, hi)) return Math.min(b.width, b.height);

  // Sonuç 2*lo olduğu için, istenen doğruluğa ulaşmak adına döngü
  // tolerance/2'de durur.
  while (hi - lo > tolerance / 2) {
    const mid = (lo + hi) / 2;
    if (isIntact(poly, mid)) lo = mid;
    else hi = mid;
  }
  return lo * 2;
}

/**
 * Parça bu ötelemede TEK parça olarak sağlam mı?
 *
 * DİKKAT: sadece "alan kaldı mı" diye bakmak yetmez. Kum saati şeklinde
 * bir parça boynundan koptuğunda iki ayrı parçaya döner ve toplam alan
 * hâlâ pozitiftir. O yüzden ölçüt "tam olarak bir dış kontur" olmalı;
 * aksi halde en dar boyun yerine tamamen yok olma eşiği ölçülür.
 */
function isIntact(poly: Polyline, inset: Mm): boolean {
  if (inset <= EPS) return true;
  const r = offsetPolygons([poly], -inset, { join: "miter" });
  const outers = r.filter((p) => signedArea(p) > EPS);
  return outers.length === 1;
}

/**
 * Verilen kenar uzunluğu için kullanılabilir iron adımı ve delik sayısı.
 *
 * Fiziksel takım sabit adımlıdır; adımı serbest seçemeyiz. Bu yüzden
 * kenarı tam bölmeye en yakın adımı seçip sapmayı raporluyoruz.
 * Sapma, delik başına düşen hatadır — 0.15mm üstü gözle görülür.
 */
export interface PitchFit {
  readonly pitch: Mm;
  readonly holes: number;
  readonly actualPitch: Mm;
  readonly deviationPerHole: Mm;
}

export function bestPitchFit(
  edgeLength: Mm,
  pitches: readonly Mm[] = IRON_PITCHES,
): PitchFit | undefined {
  let best: PitchFit | undefined;
  for (const pitch of pitches) {
    const n = Math.round(edgeLength / pitch);
    if (n < 1) continue;
    const actual = edgeLength / n;
    const dev = Math.abs(actual - pitch);
    if (best === undefined || dev < best.deviationPerHole) {
      best = {
        pitch,
        holes: n,
        actualPitch: actual,
        deviationPerHole: dev,
      };
    }
  }
  return best;
}
