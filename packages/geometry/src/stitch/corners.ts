import type { Mm } from "../units.js";
import { EPS, clamp } from "../units.js";
import type { Vec } from "../vec.js";
import {
  add,
  scale,
  sub,
  normalize,
  distance,
  dot,
  cross,
  lerp,
} from "../vec.js";
import type { Polyline } from "../path/path.js";

/**
 * KÖŞE YUVARLATMA
 *
 * NEDEN AYRI BİR ADIM: Adım 5'te ortaya çıktı ki içe öteleme (inset)
 * dışbükey köşeleri yuvarlamıyor — geometrik olarak doğru davranış, ama
 * dikiş hattı için yanlış sonuç. İplik köşeyi keskin dönmez, yay çizer.
 * Keskin köşe bırakılırsa delik dağıtıcısı orada gerçekte olmayan bir
 * kırılma görür ve iki ayrı segment gibi davranır.
 *
 * Bu yüzden yuvarlatma, offset'in yan ürünü olarak beklenmek yerine
 * bilinçli olarak uygulanır.
 */

/**
 * Bir köşeyi verilen yarıçapla yuvarlatır (fillet).
 *
 * Yarıçap komşu kenarlara sığmıyorsa otomatik küçültülür — kullanıcının
 * verdiği değeri sessizce zorlamak, kenarların üst üste binmesine ve
 * bozuk kontura yol açardı.
 */
export interface RoundCornersOptions {
  /** Yuvarlatma yarıçapı. */
  readonly radius: Mm;
  /**
   * Bu açıdan daha yumuşak dönüşler yuvarlatılmaz.
   * Düzleştirilmiş bezier'de 1–5°'lik dönüşler var; onlar köşe değil.
   */
  readonly minAngleDeg?: number;
  /**
   * Her yay kaç doğru parçasına bölünsün.
   *
   * Kirişler yaydan kısa olduğu için düşük değerler çevreyi az gösterir.
   * 12'de 5mm yarıçaplı bir köşede hata ~0.01mm — hata bütçemizin
   * (±0.5mm) çok altında. Daha yükseğe çıkmak nokta sayısını artırır,
   * PDF boyutunu büyütür, kazanç sağlamaz.
   */
  readonly arcSegments?: number;
}

export function roundCorners(
  poly: Polyline,
  closed: boolean,
  options: RoundCornersOptions,
): Polyline {
  const n = poly.length;
  if (n < 3 || options.radius <= EPS) return poly;

  const minAngleDeg = options.minAngleDeg ?? 25;
  const arcSegments = options.arcSegments ?? 12;
  const minCos = Math.cos((minAngleDeg * Math.PI) / 180);

  const out: Vec[] = [];
  const first = closed ? 0 : 1;
  const last = closed ? n - 1 : n - 2;

  if (!closed) out.push(poly[0] as Vec);

  for (let i = first; i <= last; i++) {
    const prev = poly[(i - 1 + n) % n] as Vec;
    const cur = poly[i] as Vec;
    const next = poly[(i + 1) % n] as Vec;

    // Köşeden komşulara bakan birim vektörler.
    const u = normalize(sub(prev, cur));
    const v = normalize(sub(next, cur));

    // İlerleme yönündeki dönüş açısı bu eşiğin altındaysa köşe değil.
    const forwardIn = normalize(sub(cur, prev));
    if (dot(forwardIn, normalize(sub(next, cur))) > minCos) {
      out.push(cur);
      continue;
    }

    // İç açının yarısı.
    const cosTheta = clamp(dot(u, v), -1, 1);
    const theta = Math.acos(cosTheta);
    const half = theta / 2;
    if (Math.sin(half) <= EPS || Math.tan(half) <= EPS) {
      out.push(cur);
      continue;
    }

    // Teğet mesafesi: köşeden yayın başladığı noktaya kadar.
    let tangentDist = options.radius / Math.tan(half);

    // Komşu kenarların yarısını aşamaz, yoksa yaylar birbirine girer.
    const maxDist = Math.min(
      distance(cur, prev) / 2,
      distance(cur, next) / 2,
    );
    tangentDist = Math.min(tangentDist, maxDist);
    if (tangentDist <= EPS) {
      out.push(cur);
      continue;
    }

    const effectiveRadius = tangentDist * Math.tan(half);
    const t1 = add(cur, scale(u, tangentDist));
    const t2 = add(cur, scale(v, tangentDist));

    // Yay merkezi: iç açının açıortayı boyunca.
    const bisector = normalize(add(u, v));
    const centerDist = effectiveRadius / Math.sin(half);
    const center = add(cur, scale(bisector, centerDist));

    out.push(...arcBetween(center, t1, t2, arcSegments));
  }

  if (!closed) out.push(poly[n - 1] as Vec);

  return out;
}

/**
 * center merkezli, t1'den t2'ye kısa yay.
 * Yarıçap iki uçta eşit varsayılır (fillet kurulumu bunu garanti eder).
 */
function arcBetween(
  center: Vec,
  t1: Vec,
  t2: Vec,
  segments: number,
): Vec[] {
  const a = sub(t1, center);
  const b = sub(t2, center);
  const radius = Math.hypot(a.x, a.y);
  if (radius <= EPS) return [t1];

  const startAngle = Math.atan2(a.y, a.x);
  let sweep = Math.atan2(cross(a, b), dot(a, b));

  // Fillet her zaman kısa yayı kullanır.
  if (sweep > Math.PI) sweep -= 2 * Math.PI;
  if (sweep < -Math.PI) sweep += 2 * Math.PI;

  const steps = Math.max(1, segments);
  const pts: Vec[] = [];
  for (let i = 0; i <= steps; i++) {
    const angle = startAngle + (sweep * i) / steps;
    pts.push({
      x: center.x + radius * Math.cos(angle),
      y: center.y + radius * Math.sin(angle),
    });
  }
  return pts;
}

/**
 * Dikiş hattı için önerilen köşe yarıçapı.
 *
 * Dikiş hattı kesim kenarından `margin` kadar içeride. Köşede ipliğin
 * dönüşü, kesim köşesinin yuvarlatmasıyla aynı merkezde olmalı; pratikte
 * dikiş payına eşit bir yarıçap doğal bir dönüş verir.
 */
export function suggestedStitchCornerRadius(stitchMargin: Mm): Mm {
  return stitchMargin;
}

/** İki nokta arası doğrusal ara nokta üretir (test ve yardımcı kullanım). */
export function midpoint(a: Vec, b: Vec): Vec {
  return lerp(a, b, 0.5);
}
