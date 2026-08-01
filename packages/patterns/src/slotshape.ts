import type { Mm, Path, PathBuilder, Polyline, Vec } from "@odk/geometry";
import { flattenPath, path, vec } from "@odk/geometry";

/**
 * SOKET AĞZI ŞEKİLLERİ
 *
 * ═══════════════════════════════════════════════════════════════════════
 * ÖZELLİK ŞEKLİ, GÖVDE DEĞİL
 * ═══════════════════════════════════════════════════════════════════════
 *
 * Kural 3: kalıp bir kesit çözümüdür, elle çizilmez. Bu modül o kuralı
 * KIRMAZ — kart yuvası parçasının GÖVDESİNİ (genişlik × yükseklik) motor
 * hesaplamaya devam eder. Burada değişen yalnızca o kutunun İÇİNDEKİ yerel
 * biçim: kartın girdiği ağzın profili.
 *
 * Yani "kendi soket şeklini seç" güvenli bir işlem: dış ölçü, kat payı,
 * delik yansıtma hep hesaplanmış gövdeden gelir; şekil sadece ağzı
 * değiştirir. (Faz 20'de kullanıcının çizdiği ağız da buraya "özel" bir
 * SlotShape olarak girer.)
 *
 * ÖNEMLİ: "duz" ve "t-slot" mevcut motorun ürettiği iki şekli BİREBİR
 * yeniden üretir (slotshape.test.ts bunu sabitler). Böylece varsayılan
 * bifold çıktısı bit-bit aynı kalır; yeni şekiller yalnızca opt-in.
 */

export type SlotShapeId = "duz" | "t-slot" | "kavis" | "oyuk" | "acili";

export interface SlotShapeDims {
  /** Yuva parçasının genişliği (motor hesaplar). */
  readonly width: Mm;
  /** Yuva parçasının yüksekliği (motor hesaplar). */
  readonly height: Mm;
  /** T-slot ağız (omuz) bölgesinin yüksekliği. */
  readonly mouthHeight: Mm;
  /** T-slot yan girintisi — gövde kenara ulaşmasın diye. */
  readonly sideInset: Mm;
}

export interface SlotShapeInfo {
  readonly id: SlotShapeId;
  readonly name: string;
  readonly summary: string;
  /**
   * Gövdesi omuzlu mu (kenara ulaşmıyor)? T-slot ailesinin tümü öyle;
   * bu, kenar kalınlığını sabit tutan özellik. "duz" hariç hepsi true.
   */
  readonly hasShoulders: boolean;
}

/**
 * Kullanıcıya sunulan üst-yuva ağız şekilleri.
 *
 * "duz" burada YOK: o, en alttaki yuvanın (dibi kapatan) ve "stacked"
 * yapımın şekli; kullanıcı seçimi değil. Kullanıcı üst yuvaların ağzını
 * bunlardan seçer.
 */
export const SLOT_SHAPES: readonly SlotShapeInfo[] = [
  {
    id: "t-slot",
    name: "T-slot (düz ağız)",
    summary: "Standart. Gövde kenara ulaşmaz; kenar tek katman kalır.",
    hasShoulders: true,
  },
  {
    id: "kavis",
    name: "Kavisli ağız",
    summary: "Ağız ortası hafif oyulur; kartı kavramak kolaylaşır.",
    hasShoulders: true,
  },
  {
    id: "oyuk",
    name: "Başparmak oyuğu",
    summary: "Ortada yarım daire kesik; kartı iterek çıkarmak için.",
    hasShoulders: true,
  },
  {
    id: "acili",
    name: "Açılı ağız",
    summary: "Ağız kenarı eğik; kartın üst köşesi görünür durur.",
    hasShoulders: true,
  },
];

export function slotShapeInfo(id: SlotShapeId): SlotShapeInfo | undefined {
  return SLOT_SHAPES.find((s) => s.id === id);
}

/**
 * Yuva parçasının dış hattını üretir.
 *
 * Koordinatlar: (0,0) sol-üst, y aşağı doğru artar. Ağız üst kenardadır
 * (y=0 civarı), dip tam genişlikte alttadır (y=height). "duz" ve "t-slot"
 * mevcut motorla birebir; diğerleri t-slot gövdesini paylaşır, yalnızca
 * üst ağız kenarını değiştirir (omuzlar korunur → az delik özelliği durur).
 */
export function slotShapePath(id: SlotShapeId, dims: SlotShapeDims): Polyline {
  const { width: w, height: h, mouthHeight, sideInset: si } = dims;

  // Düz dikdörtgen — mevcut rectangle(0,0,w,h) ile birebir.
  if (id === "duz") {
    return flattenPath(
      path()
        .moveTo(vec(0, 0))
        .lineTo(vec(w, 0))
        .lineTo(vec(w, h))
        .lineTo(vec(0, h))
        .close(),
    );
  }

  const shoulder = h - mouthHeight;
  const span = w - 2 * si;

  // T-slot gövdesini kapatır. `b`, üst ağız kenarının bitişinde (w-si, Y)
  // konumlanmış olmalı; buradan omuz-dip-taban gezilir. Mevcut tSlotShape
  // ile birebir aynı gövde.
  const close = (b: PathBuilder): Path =>
    b
      .lineTo(vec(w - si, shoulder))
      .lineTo(vec(w, shoulder))
      .lineTo(vec(w, h))
      .lineTo(vec(0, h))
      .lineTo(vec(0, shoulder))
      .lineTo(vec(si, shoulder))
      .close();

  switch (id) {
    case "t-slot":
      // Düz ağız — mevcut tSlotShape ile birebir.
      return flattenPath(
        close(path().moveTo(vec(si, 0)).lineTo(vec(w - si, 0))),
      );

    case "kavis": {
      // Ağız ortası aşağı kavisli. Simetrik kübiğin orta y'si ≈ 0.75×ctrlY.
      const depth = Math.min(mouthHeight * 0.55, h * 0.18);
      const ctrlY = depth / 0.75;
      return flattenPath(
        close(
          path()
            .moveTo(vec(si, 0))
            .cubicTo(
              vec(si + span * 0.28, ctrlY),
              vec(w - si - span * 0.28, ctrlY),
              vec(w - si, 0),
            ),
        ),
      );
    }

    case "oyuk": {
      // Düz ağız + ortada yarım daire (U) kesik.
      const r = Math.min(span * 0.16, mouthHeight * 0.7);
      const depth = Math.min(mouthHeight * 0.85, h * 0.22);
      const cx = w / 2;
      return flattenPath(
        close(
          path()
            .moveTo(vec(si, 0))
            .lineTo(vec(cx - r, 0))
            .cubicTo(
              vec(cx - r * 0.35, depth),
              vec(cx + r * 0.35, depth),
              vec(cx + r, 0),
            )
            .lineTo(vec(w - si, 0)),
        ),
      );
    }

    case "acili": {
      // Eğik ağız: sol köşe y=0, sağ köşe aşağıda.
      const slant = Math.min(mouthHeight * 0.7, h * 0.22);
      return flattenPath(
        close(path().moveTo(vec(si, 0)).lineTo(vec(w - si, slant))),
      );
    }
  }
}

/**
 * ═══════════════════════════════════════════════════════════════════════
 * ÖZEL AĞIZ — kullanıcının çizdiği profil
 * ═══════════════════════════════════════════════════════════════════════
 *
 * Kullanıcı ağzın üst kenarını soldan sağa bir PROFİL olarak çizer. Bu
 * profil, hazır şekillerin (kavis/oyuk/açılı) yaptığı şeyin serbest hâli:
 * yalnızca üst kenar değişir, gövde (omuzlar, dip) motorun hesabıyla kalır.
 *
 * Neden bu güvenli: noktalar NORMALİZE (u,v ∈ [0,1]) ve u SOLDAN SAĞA
 * sıralı. Sıra korunduğu için profil kendini kesemez → her zaman geçerli
 * bir basit poligon çıkar. Derinlik ağız yüksekliğinin altında tutulur, bu
 * yüzden dipler omuza değmez. Yani "kendi şeklini çiz" motorun garantilerini
 * bozmadan yapılabilir — çizim bir GÖVDE değil, bir ÖZELLİK.
 */

/** Normalize ağız noktası: u = soldan sağa (0..1), v = ağza doğru derinlik (0..1). */
export interface NormPoint {
  readonly u: number;
  readonly v: number;
}

/** Editörün başlangıç profili — hafif bir kavis. */
export const DEFAULT_CUSTOM_MOUTH: readonly NormPoint[] = [
  { u: 0, v: 0 },
  { u: 0.5, v: 0.55 },
  { u: 1, v: 0 },
];

export interface MouthValidation {
  readonly ok: boolean;
  readonly code?: string;
  readonly message?: string;
}

/**
 * Çizilen ağız profilini denetler. Motor buna güvenmeden önce geçmeli;
 * editör de aynı kuralı canlı uygular.
 */
export function validateCustomMouth(mouth: readonly NormPoint[]): MouthValidation {
  if (mouth.length < 2) {
    return {
      ok: false,
      code: "MOUTH_TOO_FEW",
      message: "Ağız için en az 2 nokta gerekli.",
    };
  }
  const first = mouth[0] as NormPoint;
  const last = mouth[mouth.length - 1] as NormPoint;
  if (Math.abs(first.u) > 1e-3 || Math.abs(last.u - 1) > 1e-3) {
    return {
      ok: false,
      code: "MOUTH_ENDPOINTS",
      message: "İlk nokta sol köşede (u=0), son nokta sağ köşede (u=1) olmalı.",
    };
  }
  for (let i = 0; i < mouth.length; i++) {
    const p = mouth[i] as NormPoint;
    if (p.u < -1e-6 || p.u > 1 + 1e-6 || p.v < -1e-6 || p.v > 1 + 1e-6) {
      return {
        ok: false,
        code: "MOUTH_OUT_OF_BOUNDS",
        message: "Noktalar çizim kutusunun dışına taşamaz.",
      };
    }
    if (i > 0 && p.u < (mouth[i - 1] as NormPoint).u - 1e-6) {
      return {
        ok: false,
        code: "MOUTH_NOT_MONOTONIC",
        message: "Noktalar soldan sağa sıralı olmalı — profil kendini kesemez.",
      };
    }
  }
  return { ok: true };
}

/**
 * Çizilen profili yuva parçasının dış hattına çevirir.
 *
 * Üst kenar = denormalize edilmiş profil; gövde = t-slot ile aynı (omuzlar
 * + dip). Derinlik ağız yüksekliğinin %90'ıyla sınırlı, omuz hattına değmez.
 * Geçersiz profil verilirse düz t-slot'a düşer (motor asla kırılmaz).
 */
export function customMouthPath(
  mouth: readonly NormPoint[],
  dims: SlotShapeDims,
): Polyline {
  if (!validateCustomMouth(mouth).ok) {
    return slotShapePath("t-slot", dims);
  }
  const { width: w, height: h, mouthHeight, sideInset: si } = dims;
  const shoulder = h - mouthHeight;
  const depthMax = mouthHeight * 0.9;
  const px = (u: number): Mm => si + u * (w - 2 * si);
  const py = (v: number): Mm => v * depthMax;

  const pts = mouth.map((p) => vec(px(p.u), py(p.v)));
  let b: PathBuilder = path().moveTo(pts[0] as Vec);
  for (let i = 1; i < pts.length; i++) b = b.lineTo(pts[i] as Vec);
  const closed: Path = b
    .lineTo(vec(w - si, shoulder))
    .lineTo(vec(w, shoulder))
    .lineTo(vec(w, h))
    .lineTo(vec(0, h))
    .lineTo(vec(0, shoulder))
    .lineTo(vec(si, shoulder))
    .close();
  return flattenPath(closed);
}
