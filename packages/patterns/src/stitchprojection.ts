import type { Mm, Polyline, StitchPlan, StitchHole, Vec } from "@odk/geometry";
import { offsetPolygons, pointInPolygon } from "@odk/geometry";

/**
 * DİKİŞ PLANI PROJEKSİYONU
 *
 * ═══════════════════════════════════════════════════════════════════════
 * NEDEN HER PARÇA İÇİN AYRI DAĞITIM YAPILMIYOR
 * ═══════════════════════════════════════════════════════════════════════
 *
 * Çevre dikişi bütün katmanlardan aynı anda geçer: dış kabuk, iç kabuk
 * ve kenara ulaşan yuva parçaları tek bir iplikle birlikte dikilir.
 * Dolayısıyla deliklerin HİZALANMASI zorunlu.
 *
 * Her parçaya bağımsız `distributeStitches` çağırmak felaket olurdu:
 * parçaların çevre uzunlukları farklı, köşe konumları farklı, dolayısıyla
 * delik konumları da farklı çıkardı. Kağıtta düzgün görünen ama üst üste
 * konduğunda tutmayan delikler.
 *
 * Doğru yol: çevre dikişi TEK KEZ, birleşik dış hat üzerinde planlanır;
 * sonra her parçaya kendi sınırları içine düşen delikler yansıtılır.
 * Böylece bütün parçalardaki delikler tanım gereği aynı noktalardır.
 *
 * ═══════════════════════════════════════════════════════════════════════
 * KENAR TOLERANSI
 * ═══════════════════════════════════════════════════════════════════════
 *
 * Delikler parçanın kesim hattının biraz İÇİNDE, dikiş payı kadar
 * mesafede. Ama yuva parçasının kenarı çoğu zaman tam olarak ana
 * parçanın kenarıyla çakışıyor ve nokta-poligon testi kenar üstünde
 * kararsız. Bu yüzden test edilen poligon önce dışa ötelenir.
 */

/**
 * Kat payı SIRTTA soğurulan parçalar için projeksiyon.
 *
 * İç kabuk dış kabuktan kat payı kadar kısa. Ama montajda ortalanmıyor:
 * sol kenarı dış kabuğun sol kenarıyla, sağ kenarı sağ kenarıyla
 * hizalanıyor; eksik uzunluk sırtta kapanıyor.
 *
 * İlk sürümde ortalanmış varsaymıştım ve iç kabuğa 143 yerine 105 delik
 * düşüyordu — yan kenarların tamamı kaybolmuştu. Oysa iç kabuk çevre
 * dikişine tam boyunca yakalanır.
 *
 * Bu yüzden delikler sırt çizgisinin hangi tarafında olduğuna göre
 * kaydırılıyor: sol taraf olduğu gibi, sağ taraf kat payı kadar sola.
 */
export function projectAcrossFold(
  master: StitchPlan,
  foldAxis: Mm,
  shortfall: Mm,
  pieceOutline: Polyline,
  vertical: boolean,
  tolerance: Mm = PROJECTION_TOLERANCE,
): ProjectionResult {
  const shifted: StitchPlan = {
    ...master,
    holes: master.holes.map((h) => {
      const along = vertical ? h.position.x : h.position.y;
      if (along < foldAxis) return h;
      return {
        ...h,
        position: vertical
          ? { x: h.position.x - shortfall, y: h.position.y }
          : { x: h.position.x, y: h.position.y - shortfall },
      };
    }),
  };
  return projectStitchPlan(shifted, { x: 0, y: 0 }, pieceOutline, tolerance);
}

/** Kenar üstündeki delikleri güvenli yakalamak için genişletme payı. */
export const PROJECTION_TOLERANCE: Mm = 0.5;

export interface ProjectionResult {
  readonly plan: StitchPlan | undefined;
  /** Bu parçaya düşen delik sayısı. */
  readonly count: number;
}

/**
 * Ana dikiş planından bir parçaya düşen delikleri çıkarır.
 *
 * @param master     Birleşik dış hat üzerinde hesaplanmış plan.
 *                   Delik konumları MONTAJ koordinatında.
 * @param offset     Parçanın montajdaki sol-alt köşesi.
 * @param pieceOutline Parçanın KENDİ koordinatındaki kesim hattı.
 */
export function projectStitchPlan(
  master: StitchPlan,
  offset: Vec,
  pieceOutline: Polyline,
  tolerance: Mm = PROJECTION_TOLERANCE,
): ProjectionResult {
  if (pieceOutline.length < 3) return { plan: undefined, count: 0 };

  const grown = offsetPolygons([pieceOutline], tolerance, { join: "miter" });
  const test = (grown[0] ?? pieceOutline) as Polyline;

  const minX = Math.min(...pieceOutline.map((p) => p.x));
  const minY = Math.min(...pieceOutline.map((p) => p.y));
  const testMinX = Math.min(...test.map((p) => p.x));
  const testMinY = Math.min(...test.map((p) => p.y));

  const holes: StitchHole[] = [];
  for (const hole of master.holes) {
    // Montaj koordinatı -> parça yerel koordinatı.
    const local: Vec = {
      x: hole.position.x - offset.x,
      y: hole.position.y - offset.y,
    };
    // Genişletilmiş poligon kendi çerçevesinde kaydığı için testi
    // aynı hizaya getiriyoruz.
    const probe: Vec = {
      x: local.x - minX + testMinX,
      y: local.y - minY + testMinY,
    };
    if (pointInPolygon(test, probe)) {
      holes.push({ ...hole, position: local });
    }
  }

  if (holes.length === 0) return { plan: undefined, count: 0 };

  return {
    plan: {
      holes,
      // Segment planı ana plandan devralınıyor: parçadaki delikler ana
      // planın alt kümesi olduğu için adım ve sapma da aynı.
      spans: master.spans,
      pitch: master.pitch,
      totalHoles: holes.length,
      maxDeviation: master.maxDeviation,
      warnings: [],
    },
    count: holes.length,
  };
}
