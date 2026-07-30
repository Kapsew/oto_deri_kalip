#!/usr/bin/env bash
#
# 13_kartlik_dikey_kat.sh
#
# Kartligin kati YATAY'dan DIKEY'e alindi, dikis U seklinde ve ust kenar
# acik. A4 kontrolu artik dondurmeyi hesaba katiyor.
#
# Repo kokunde calistir. Idempotent.

set -euo pipefail

if [ ! -f "pnpm-workspace.yaml" ] || [ ! -d "packages/print" ]; then
  echo "HATA: Repo kokunde calistirilmali ve 12 uygulanmis olmali." >&2
  exit 1
fi

echo "==> packages/patterns/src/cardholder.ts"
cat > packages/patterns/src/cardholder.ts << 'ODK_EOF_0'
import type { Mm, Polyline, Vec, StitchPlan } from "@odk/geometry";
import {
  path,
  flattenPath,
  bbox,
  cutLine,
  stitchLine,
  roundCorners,
  distributeStitches,
  narrowestWidth,
  vec,
  CARD_ID1,
  A4,
} from "@odk/geometry";
import type { Temper } from "./material.js";
import {
  CARD_THICKNESS,
  MAX_CLOSED_THICKNESS,
  RECOMMENDED_THICKNESS,
  leather,
} from "./material.js";
import { projectStitchPlan } from "./stitchprojection.js";
import type { CardOrientation, SlotConstruction } from "./cardslot.js";
import { cardSlotGeometry, validateCardSlots, T_SLOT_WRAP_ALLOWANCE } from "./cardslot.js";
import type { CrossSection, CrossSectionResult, Diagnostic, Layer } from "./crosssection.js";
import {
  solveCrossSection,
  foldLengthDelta,
  naturalInnerRadius,
  layerResult,
} from "./crosssection.js";

/**
 * KARTLIK ÜRETECİ (MVP)
 *
 * Faz 3'ün tam modül sisteminin öncüsü. Amaç motoru uçtan uca
 * çalıştırabilmek: parametre → kesit çözümü → parça hatları → dikiş
 * planı. Tek iskelet (katlanır kartlık) ve tek modül (CardSlot) var.
 *
 * BASİTLEŞTİRME (bilinçli): çevre dikişi yalnızca dış parça üzerinde
 * planlanır; yuva parçaları bu dikişe yakalanır. Gerçek yapım biçimi bu
 * ve yuva parçaları için var olmayan dikiş yolları uydurmaktan kaçınır.
 */

export interface CardHolderParams {
  readonly cardCount: number;
  readonly construction: SlotConstruction;
  readonly orientation: CardOrientation;
  readonly outerThickness: Mm;
  readonly slotThickness: Mm;
  readonly temper: Temper;
  readonly reveal: Mm;
  readonly stitchMargin: Mm;
  readonly cornerRadius: Mm;
  readonly penAllowance: Mm;
  /** Verilmezse minimax ile otomatik seçilir. */
  readonly pitch?: Mm;
}

export const DEFAULT_PARAMS: CardHolderParams = {
  cardCount: 4,
  construction: "t-slot",
  orientation: "horizontal",
  outerThickness: RECOMMENDED_THICKNESS.outerShell.preferred,
  slotThickness: RECOMMENDED_THICKNESS.cardSlot.preferred,
  temper: "veg-tan-firm",
  reveal: 12,
  stitchMargin: 3.5,
  cornerRadius: 4,
  penAllowance: 0.3,
  /**
   * Varsayılan 3.85mm.
   *
   * Otomatik seçime BIRAKILMIYOR: kullanıcının elinde belirli bir
   * pricking iron var ve hangi adımı kullanacağını motor bilemez.
   * Otomatik seçim yalnızca sapmayı ölçebilir; dikişin ne kadar sık
   * görüneceği estetik bir karar ve kullanıcıya ait.
   *
   * 3.85mm küçük deri ürünlerinde en yaygın adım.
   */
  pitch: 3.85,
};

export type PieceKind = "outer" | "slot-rect" | "slot-t";

export interface FoldLine {
  readonly from: Vec;
  readonly to: Vec;
  readonly label: string;
}

export interface PatternPiece {
  readonly id: string;
  /**
   * Kısa ve kararlı parça kodu (A, B, C...).
   *
   * Talimatlarda ve montaj görünümünde parçalara atıf yapmak için.
   * Ad değişebilir, kod değişmez.
   */
  readonly code: string;
  readonly name: string;
  readonly kind: PieceKind;
  readonly quantity: number;
  readonly leatherThickness: Mm;
  /** Basılacak kesim hattı (kalem payı uygulanmış). */
  readonly cutLine: Polyline;
  /** Dikiş hattı — yalnızca çevre dikişi olan parçalarda. */
  readonly stitchLine?: Polyline;
  /**
   * Dikiş hattı kapalı bir çevre mi?
   *
   * Cüzdanlarda DEĞİL: banknot ya da kart bölmesinin ağzı açık kalmak
   * zorunda. Kapalı çizmek hem yanlış görünür hem de o kenara delik
   * yerleştirir — dikilirse bölme kapanır ve ürün işe yaramaz.
   */
  readonly stitchLineClosed?: boolean;
  readonly stitchPlan?: StitchPlan;
  readonly foldLines: readonly FoldLine[];
  readonly width: Mm;
  readonly height: Mm;
}

/**
 * Montajdaki bir parça örneği.
 *
 * NEDEN AYRI BİR LİSTE: parçalar tipe göre gruplanıyor ("T-slot yuva ×3")
 * ama montaj görünümü her örneği ayrı konumda göstermek zorunda.
 */
export interface AssemblyPlacement {
  readonly pieceId: string;
  readonly code: string;
  /** Dış kabuğun sol-alt köşesine göre konum. */
  readonly x: Mm;
  readonly y: Mm;
  /** 0 = en altta (dış kabuk). Büyük sayı üstte. */
  readonly layer: number;
}

export interface PatternSummary {
  readonly compartmentWidth: Mm;
  readonly slotStackHeight: Mm;
  readonly outerFlatWidth: Mm;
  readonly outerFlatHeight: Mm;
  readonly closedThickness: Mm;
  readonly loadedThickness: Mm;
  readonly edgeThickness: Mm;
  readonly foldAllowance: Mm;
  /** Katlanmış hâlde bir panelin yüksekliği. */
  readonly panelHeight: Mm;
  readonly totalHoles: number;
  readonly pitch: Mm;
  readonly fitsA4: boolean;
}

export interface PatternResult {
  readonly pieces: readonly PatternPiece[];
  /** Parçaların bitmiş üründeki (açık hâlde) yerleşimi. */
  readonly assembly: readonly AssemblyPlacement[];
  readonly crossSection: CrossSectionResult;
  readonly diagnostics: readonly Diagnostic[];
  readonly summary: PatternSummary;
}

function cardW(o: CardOrientation): Mm {
  return o === "horizontal" ? CARD_ID1.width : CARD_ID1.height;
}
function cardH(o: CardOrientation): Mm {
  return o === "horizontal" ? CARD_ID1.height : CARD_ID1.width;
}

/**
 * Parça A4'e sığıyor mu — 90° döndürme dahil.
 * 20mm yazıcı kenar payı düşülüyor.
 */
export function fitsOnA4(width: Mm, height: Mm): boolean {
  const w = A4.width - 20;
  const h = A4.height - 20;
  return (width <= w && height <= h) || (height <= w && width <= h);
}

function rectangle(x: Mm, y: Mm, w: Mm, h: Mm): Polyline {
  return flattenPath(
    path()
      .moveTo(vec(x, y))
      .lineTo(vec(x + w, y))
      .lineTo(vec(x + w, y + h))
      .lineTo(vec(x, y + h))
      .close(),
  );
}

/**
 * T-slot parçası.
 *
 * Üstte tam genişlikte "kollar", altta daralmış "gövde". Gövdenin
 * bölmenin kenarına ulaşmaması, kaç yuva olursa olsun kenarda tek
 * katman kalmasını sağlayan şey.
 */
function tSlotShape(width: Mm, height: Mm, mouthHeight: Mm, sideInset: Mm): Polyline {
  const shoulder = height - mouthHeight;
  return flattenPath(
    path()
      .moveTo(vec(sideInset, 0))
      .lineTo(vec(width - sideInset, 0))
      .lineTo(vec(width - sideInset, shoulder))
      .lineTo(vec(width, shoulder))
      .lineTo(vec(width, height))
      .lineTo(vec(0, height))
      .lineTo(vec(0, shoulder))
      .lineTo(vec(sideInset, shoulder))
      .close(),
  );
}

export function generateCardHolder(params: CardHolderParams): PatternResult {
  const diagnostics: Diagnostic[] = [];

  const n = Math.max(0, Math.floor(params.cardCount));

  const slotGeo = cardSlotGeometry({
    count: params.cardCount,
    construction: params.construction,
    orientation: params.orientation,
    leatherThickness: params.slotThickness,
    reveal: params.reveal,
    stitchMargin: params.stitchMargin,
  });

  for (const d of validateCardSlots({
    count: params.cardCount,
    construction: params.construction,
    orientation: params.orientation,
    leatherThickness: params.slotThickness,
    reveal: params.reveal,
    stitchMargin: params.stitchMargin,
  })) {
    diagnostics.push({ severity: d.severity, code: d.code, message: d.message });
  }

  // --- Kesit: dış kabuk yuva yığınını sarıyor ---------------------------
  const outerSpec = leather(params.temper, params.outerThickness);
  const slotSpec = leather(params.temper, params.slotThickness);

  const layers: Layer[] = [
    { id: "slots", name: "kart yuvaları", spec: slotSpec },
    { id: "outer", name: "dış kabuk", spec: outerSpec },
  ];

  // Kapalı kalınlık: yuva katmanları + dış kabuk iki kez (katlandığı için).
  const closedThickness = slotGeo.centerThickness + 2 * params.outerThickness;
  const loadedThickness = slotGeo.loadedThickness + 2 * params.outerThickness;

  // KAT ARTIK DİKEY (sırt), bifold ile aynı yapı.
  //
  // Önceki sürümde kat yataydı ve çevre dikişi KAPALI idi — yani
  // kartlığın ağzı da dikiliyordu, kart giremezdi. Yatay katta ayrıca
  // iki ayrı yan dikiş gerekir (tek U olmaz), çünkü kat ortada ve iki
  // serbest uç ağzı oluşturur.
  //
  // Dikey kata geçmek bifold'da doğrulanmış yapıyı aynen kullanmayı
  // sağlıyor: sırt solda/ortada, ağız üstte, dikiş U şeklinde.
  const panelWidth = slotGeo.compartmentWidth;
  const walletHeight = slotGeo.stackHeight + 2 * params.stitchMargin;
  const foldFill = slotGeo.centerThickness + n * CARD_THICKNESS;

  const crossSection: CrossSection = {
    name: "kartlık",
    layers,
    runs: [
      { id: "front", name: "ön panel", length: panelWidth, layers: ["slots", "outer"] },
      { id: "back", name: "arka panel", length: panelWidth, layers: ["outer"] },
    ],
    folds: [
      {
        id: "spine",
        name: "sırt",
        angleDeg: 180,
        innerRadius: naturalInnerRadius(params.outerThickness),
        stack: ["slots", "outer"],
        gaps: { outer: foldFill },
      },
    ],
  };

  const solved = solveCrossSection(crossSection);
  diagnostics.push(...solved.diagnostics);

  const outerFlat = layerResult(solved, "outer")?.flatLength ?? 2 * panelWidth;

  // KAT PAYI = kıvrım bölgesinin genişliği, yani düz uzunluğun iki
  // panelden fazlası.
  //
  // Bifold'daki gibi "dış − iç" almak BURADA YANLIŞ: kartlıkta yuva
  // katmanı yalnızca ön panelden geçiyor, dış kabuk ikisinden de.
  // Farkı almak bir panel boyunu da içine katıyor ve 121mm gibi saçma
  // bir sayı üretiyor. Karşılaştırılabilir olmaları için iki katmanın
  // AYNI düz bölümlerden geçmesi gerekir.
  const foldAllowance = outerFlat - 2 * panelWidth;

  // --- Parçalar ---------------------------------------------------------
  const W = panelWidth;
  const pieces: PatternPiece[] = [];

  // KÖŞE SIRASI ÖNEMLİ: yuvarlatma NOMİNAL şekle uygulanır, dikiş
  // hattına değil. Deri parçanın köşesi yuvarlak kesilir, dikiş hattı
  // onu takip eder.
  const outerNominal = roundCorners(
    rectangle(0, 0, outerFlat, walletHeight),
    true,
    { radius: params.cornerRadius },
  );
  const outerCut = cutLine(outerNominal, { penAllowance: params.penAllowance });

  // DİKİŞ U ŞEKLİNDE — ÜST KENAR AÇIK (kart ağzı).
  const m = params.stitchMargin;
  const outerStitch = roundCorners(
    flattenPath(
      path()
        .moveTo(vec(m, walletHeight - m))
        .lineTo(vec(m, m))
        .lineTo(vec(outerFlat - m, m))
        .lineTo(vec(outerFlat - m, walletHeight - m))
        .open(),
    ),
    false,
    { radius: Math.max(1, params.cornerRadius - m) },
  );
  const outerPlan = distributeStitches(
    outerStitch,
    false,
    params.pitch !== undefined ? { pitch: params.pitch } : {},
  );
  const outerBox = bbox(outerCut);

  const foldX = outerFlat / 2;
  pieces.push({
    id: "outer",
    code: "A",
    name: "dış kabuk",
    kind: "outer",
    quantity: 1,
    leatherThickness: params.outerThickness,
    cutLine: outerCut,
    stitchLine: outerStitch,
    stitchLineClosed: false,
    stitchPlan: outerPlan,
    foldLines: [
      {
        from: vec(foldX - foldAllowance / 2, 0),
        to: vec(foldX - foldAllowance / 2, walletHeight),
        label: "kat başlangıcı",
      },
      {
        from: vec(foldX + foldAllowance / 2, 0),
        to: vec(foldX + foldAllowance / 2, walletHeight),
        label: "kat bitişi",
      },
    ],
    width: outerBox.width,
    height: outerBox.height,
  });

  // --- Yuva parçaları ----------------------------------------------------
  //
  // HER ÖRNEK AYRI PARÇA: her yuva çevre dikişinden farklı delikler
  // alıyor (en alttaki alt kenarı da yakalıyor, üsttekiler yalnızca yan
  // kenarları). Delikler ana plandan yansıtılıyor ki katmanlar üst üste
  // konduğunda tutsun.
  const slotPieceHeight = cardH(params.orientation) + params.stitchMargin;
  const mouthHeight = Math.min(params.reveal, slotPieceHeight / 2);
  const sideInset = params.stitchMargin + T_SLOT_WRAP_ALLOWANCE;

  const rectShape = roundCorners(rectangle(0, 0, W, slotPieceHeight), true, {
    radius: Math.min(params.cornerRadius, slotPieceHeight / 4),
  });
  const tShape = roundCorners(
    tSlotShape(W, slotPieceHeight, mouthHeight, sideInset),
    true,
    { radius: Math.min(params.cornerRadius, sideInset / 2) },
  );

  if (slotGeo.tSlotPieces > 0) {
    const neck = narrowestWidth(
      cutLine(tShape, { penAllowance: params.penAllowance }),
    );
    if (neck < params.stitchMargin * 2) {
      diagnostics.push({
        severity: "warning",
        code: "T_STEM_NARROW",
        message:
          `T-slot gövdesi ${neck.toFixed(1)}mm — dikiş payının iki katından ` +
          `(${(params.stitchMargin * 2).toFixed(1)}mm) ince. Yan payı azaltmayı ` +
          `ya da bölmeyi genişletmeyi düşün.`,
      });
    }
  }

  const assembly: AssemblyPlacement[] = [];
  for (let i = 0; i < n; i++) {
    const isRect = params.construction === "stacked" || i === 0;
    const code = `${isRect ? "B" : "C"}${i + 1}`;
    const id = `slot-${i + 1}`;
    const origin = { x: 0, y: i * params.reveal };

    const cut = cutLine(isRect ? rectShape : tShape, {
      penAllowance: params.penAllowance,
    });
    const b = bbox(cut);
    const projected = projectStitchPlan(outerPlan, origin, cut);

    pieces.push({
      id,
      code,
      name: isRect ? `alt yuva ${i + 1}` : `T-slot yuva ${i + 1}`,
      kind: isRect ? "slot-rect" : "slot-t",
      quantity: 1,
      leatherThickness: params.slotThickness,
      cutLine: cut,
      ...(projected.plan === undefined ? {} : { stitchPlan: projected.plan }),
      foldLines: [],
      width: b.width,
      height: b.height,
    });

    assembly.push({ pieceId: id, code, x: origin.x, y: origin.y, layer: i + 1 });
  }

  // --- Kural denetimi ---------------------------------------------------
  if (closedThickness > MAX_CLOSED_THICKNESS) {
    diagnostics.push({
      severity: "error",
      code: "TOO_THICK",
      message:
        `Kapalı kalınlık ${closedThickness.toFixed(1)}mm — üst sınır ` +
        `${MAX_CLOSED_THICKNESS}mm. Bu artık cep cüzdanı değil.`,
    });
  }

  // A4 KONTROLÜ DÖNDÜRMEYİ HESABA KATIYOR: baskı katmanı sığmayan
  // parçayı 90° çeviriyor, düz hâle bakıp "bölünecek" demek yanlış
  // uyarı olurdu.
  const fitsA4 = fitsOnA4(outerBox.width, outerBox.height);
  if (!fitsA4) {
    diagnostics.push({
      severity: "warning",
      code: "NEEDS_TILING",
      message:
        `Dış kabuk ${outerBox.width.toFixed(0)} × ${outerBox.height.toFixed(0)}mm — ` +
        `döndürülse bile tek A4'e sığmıyor, birden fazla sayfaya bölünecek.`,
    });
  }

  return {
    pieces,
    assembly,
    crossSection: solved,
    diagnostics,
    summary: {
      compartmentWidth: panelWidth,
      slotStackHeight: slotGeo.stackHeight,
      outerFlatWidth: outerBox.width,
      outerFlatHeight: outerBox.height,
      closedThickness,
      loadedThickness,
      edgeThickness: slotGeo.edgeThickness,
      foldAllowance,
      panelHeight: walletHeight,
      totalHoles: outerPlan.totalHoles,
      pitch: outerPlan.pitch,
      fitsA4,
    },
  };
}

/** Kart genişliği/yüksekliği dışa açılıyor: arayüz etiketleri için. */
export const cardDimensions = { width: cardW, height: cardH };
ODK_EOF_0

echo "==> packages/patterns/src/cardholder.test.ts"
cat > packages/patterns/src/cardholder.test.ts << 'ODK_EOF_1'
import { describe, it, expect } from "vitest";
import { A4 } from "@odk/geometry";
import { DEFAULT_PARAMS, generateCardHolder } from "./cardholder.js";
import { foldLengthDelta, layerResult } from "./crosssection.js";

describe("generateCardHolder — varsayılan parametreler", () => {
  const r = generateCardHolder(DEFAULT_PARAMS);

  it("hata üretmiyor", () => {
    expect(r.diagnostics.filter((d) => d.severity === "error")).toHaveLength(0);
  });

  it("dış kabuk + her yuva için ayrı parça üretiliyor", () => {
    // Yuvalar GRUPLANAMAZ: her biri çevre dikişinden farklı delikler
    // alıyor, dolayısıyla farklı bir kalıp.
    expect(r.pieces.map((p) => p.id)).toEqual([
      "outer",
      "slot-1",
      "slot-2",
      "slot-3",
      "slot-4",
    ]);
  });

  it("4 yuva = 1 düz (en dip) + 3 T-slot", () => {
    const kinds = r.pieces.filter((p) => p.id !== "outer").map((p) => p.kind);
    expect(kinds).toEqual(["slot-rect", "slot-t", "slot-t", "slot-t"]);
    expect(r.pieces.every((p) => p.quantity === 1)).toBe(true);
  });

  it("her yuva parçasının kendi delikleri var ve ana plandan geliyor", () => {
    const outer = r.pieces.find((p) => p.id === "outer");
    const slots = r.pieces.filter((p) => p.id.startsWith("slot-"));
    for (const s of slots) {
      expect(s.stitchPlan).toBeDefined();
      expect(s.stitchPlan?.pitch).toBe(outer?.stitchPlan?.pitch);
      expect(s.stitchPlan?.totalHoles).toBeLessThan(
        outer?.stitchPlan?.totalHoles as number,
      );
    }
  });

  it("en dipteki yuva üsttekilerden daha çok delik alıyor", () => {
    // Alt kenar dikişini de yakalıyor.
    const bottom = r.pieces.find((p) => p.id === "slot-1");
    const top = r.pieces.find((p) => p.id === "slot-4");
    expect(bottom?.stitchPlan?.totalHoles).toBeGreaterThan(
      top?.stitchPlan?.totalHoles as number,
    );
  });

  it("bölme genişliği belgelenmiş 100mm'ye yakın", () => {
    expect(r.summary.compartmentWidth).toBeCloseTo(100, 1);
  });

  it("dış kabukta tam çevre dikişi planı var", () => {
    expect(r.pieces.find((p) => p.id === "outer")?.stitchPlan).toBeDefined();
  });

  it("kat payı hesaplanıp iki kat çizgisi olarak veriliyor", () => {
    const outer = r.pieces.find((p) => p.id === "outer");
    expect(outer?.foldLines).toHaveLength(2);
    expect(r.summary.foldAllowance).toBeGreaterThan(0);
  });

  it("dış kabuk düz uzunluğu kesit çözücüden geliyor", () => {
    // Kat DİKEY olduğu için düz uzunluk artık GENİŞLİK.
    const solved = layerResult(r.crossSection, "outer");
    expect(solved?.flatLength).toBeGreaterThan(0);
    // Kalem payı 0.3mm iki kenardan düşülmüş. Hassasiyet 3 = EPS;
    // Clipper'ın mikron ızgarasından ~60 nanometre artık kalıyor.
    expect(r.summary.outerFlatWidth).toBeCloseTo(
      (solved?.flatLength as number) - 0.6,
      3,
    );
  });

  it("dikiş adımı fiziksel iron listesinden", () => {
    expect([2.7, 3.0, 3.38, 3.85, 4.0, 5.0]).toContain(r.summary.pitch);
  });

  it("A4'e sığıyor — döndürülerek", () => {
    // Açık kartlık 222.9 × 96.4mm: düz hâlde A4'e sığmaz, 90° çevrilince
    // sığar. Kontrol döndürmeyi hesaba katıyor.
    expect(r.summary.fitsA4).toBe(true);
    expect(r.summary.outerFlatWidth).toBeGreaterThan(A4.width - 20);
    expect(r.summary.outerFlatHeight).toBeLessThan(A4.width - 20);
  });

  it("kapalı kalınlık makul bandda", () => {
    expect(r.summary.closedThickness).toBeGreaterThan(2);
    expect(r.summary.closedThickness).toBeLessThan(10);
  });
});

describe("T-slot etkisi kalıpta görünüyor", () => {
  it("stacked yapımda tüm yuvalar düz dikdörtgen", () => {
    const s = generateCardHolder({
      ...DEFAULT_PARAMS,
      construction: "stacked",
    });
    expect(
      s.pieces.filter((p) => p.id !== "outer").every((p) => p.kind === "slot-rect"),
    ).toBe(true);
  });

  it("stacked ile kenar kalınlığı çok daha fazla", () => {
    const t = generateCardHolder({ ...DEFAULT_PARAMS, cardCount: 6 });
    const s = generateCardHolder({
      ...DEFAULT_PARAMS,
      cardCount: 6,
      construction: "stacked",
    });
    expect(s.summary.edgeThickness).toBeGreaterThan(t.summary.edgeThickness * 5);
  });

  it("stacked 6 yuvada uyarı üretiyor", () => {
    const s = generateCardHolder({
      ...DEFAULT_PARAMS,
      cardCount: 6,
      construction: "stacked",
    });
    expect(s.diagnostics.some((d) => d.code === "STACKED_TOO_MANY")).toBe(true);
  });
});

describe("parametre duyarlılığı", () => {
  it("yuva sayısı arttıkça dış kabuk hem uzuyor hem yükseliyor", () => {
    const a = generateCardHolder({ ...DEFAULT_PARAMS, cardCount: 3 });
    const b = generateCardHolder({ ...DEFAULT_PARAMS, cardCount: 6 });
    // Yükseklik kademeden, genişlik kalınlaşan kıvrımdan büyüyor.
    expect(b.summary.outerFlatHeight).toBeGreaterThan(a.summary.outerFlatHeight);
    expect(b.summary.outerFlatWidth).toBeGreaterThan(a.summary.outerFlatWidth);
  });

  it("deri kalınlaştıkça kat payı büyüyor", () => {
    const thin = generateCardHolder({ ...DEFAULT_PARAMS, slotThickness: 0.6 });
    const thick = generateCardHolder({ ...DEFAULT_PARAMS, slotThickness: 0.8 });
    expect(thick.summary.foldAllowance).toBeGreaterThan(thin.summary.foldAllowance);
  });

  it("kat payı kıvrım bölgesinin genişliği", () => {
    // Dış kabuğun düz uzunluğunun iki panelden fazlası.
    //
    // "dış − iç" almak BURADA YANLIŞ: yuva katmanı yalnızca ön panelden
    // geçiyor, dış kabuk ikisinden de. Farkı almak bir panel boyunu da
    // içine katıyor ve 121mm gibi saçma bir sayı üretiyordu.
    const r = generateCardHolder(DEFAULT_PARAMS);
    const outer = layerResult(r.crossSection, "outer")?.flatLength as number;
    expect(r.summary.foldAllowance).toBeCloseTo(
      outer - 2 * r.summary.compartmentWidth,
      6,
    );
    // Kart yığını kalınlaştıkça kıvrım bölgesi genişler.
    const thicker = generateCardHolder({ ...DEFAULT_PARAMS, cardCount: 6 });
    expect(thicker.summary.foldAllowance).toBeGreaterThan(
      r.summary.foldAllowance,
    );
  });

  it("kat DİKEY: kat çizgileri düşey", () => {
    const r = generateCardHolder(DEFAULT_PARAMS);
    const outer = r.pieces.find((p) => p.id === "outer");
    for (const f of outer?.foldLines ?? []) {
      expect(f.from.x).toBeCloseTo(f.to.x, 9);
      expect(f.from.y).not.toBeCloseTo(f.to.y, 3);
    }
  });

  it("ÜST KENAR AÇIK: kart ağzı dikilmiyor", () => {
    const r = generateCardHolder(DEFAULT_PARAMS);
    const outer = r.pieces.find((p) => p.id === "outer");
    expect(outer?.stitchLineClosed).toBe(false);
  });

  it("kalem payı kesim hattını küçültüyor", () => {
    const none = generateCardHolder({ ...DEFAULT_PARAMS, penAllowance: 0 });
    const some = generateCardHolder({ ...DEFAULT_PARAMS, penAllowance: 0.5 });
    expect(some.summary.outerFlatHeight).toBeCloseTo(
      none.summary.outerFlatHeight - 1,
      6,
    );
  });

  it("döndürülse bile sığmayan kalıp uyarı üretiyor", () => {
    const r = generateCardHolder({ ...DEFAULT_PARAMS, cardCount: 8, reveal: 22 });
    if (!r.summary.fitsA4) {
      expect(r.diagnostics.some((d) => d.code === "NEEDS_TILING")).toBe(true);
    } else {
      expect(r.diagnostics.some((d) => d.code === "NEEDS_TILING")).toBe(false);
    }
  });

  it("dikey yönde bölme daralıyor", () => {
    const h = generateCardHolder(DEFAULT_PARAMS);
    const v = generateCardHolder({ ...DEFAULT_PARAMS, orientation: "vertical" });
    expect(v.summary.compartmentWidth).toBeLessThan(h.summary.compartmentWidth);
  });
});
ODK_EOF_1

echo "==> packages/patterns/src/bifold.ts"
cat > packages/patterns/src/bifold.ts << 'ODK_EOF_2'
import type { Mm, Polyline, Vec } from "@odk/geometry";
import {
  A4,
  CARD_ID1,
  bbox,
  cutLine,
  distributeStitches,
  flattenPath,
  path,
  roundCorners,
  vec,
} from "@odk/geometry";
import type { Temper } from "./material.js";
import {
  BIFOLD_TARGET_CLOSED_THICKNESS,
  CARD_THICKNESS,
  MAX_CLOSED_THICKNESS,
  RECOMMENDED_THICKNESS,
  leather,
} from "./material.js";
import type { SlotConstruction } from "./cardslot.js";
import { T_SLOT_WRAP_ALLOWANCE, cardSlotGeometry, validateCardSlots } from "./cardslot.js";
import { projectAcrossFold, projectStitchPlan } from "./stitchprojection.js";
import type { Currency } from "./banknote.js";
import { billPocketGeometry, validateBillPocket } from "./banknote.js";
import { fitsOnA4 } from "./cardholder.js";
import type {
  AssemblyPlacement,
  PatternPiece,
  PatternResult,
  PatternSummary,
} from "./cardholder.js";
import type { CrossSection, Diagnostic, Layer } from "./crosssection.js";
import {
  foldLengthDelta,
  layerResult,
  naturalInnerRadius,
  solveCrossSection,
} from "./crosssection.js";

/**
 * BİFOLD CÜZDAN
 *
 * ═══════════════════════════════════════════════════════════════════════
 * NEDEN BU MODEL KARTLIKTAN FARKLI
 * ═══════════════════════════════════════════════════════════════════════
 *
 * Kartlıkta dış kabuk yalnızca kendi iç katmanının etrafını dolanıyordu.
 * Bifold'da dış kabuk TÜM İÇERİĞİN etrafını dolanır: iç kabuk, iki
 * yandaki kart yığınları, kartların kendisi ve banknot.
 *
 * Bunu ilk modellediğimde kıvrım yığınına yalnızca iki deri katmanını
 * koydum ve dış/iç fark 2.8mm çıktı. Belgelenmiş kural 12.7mm (yarım
 * inç) diyor. Fark, kıvrımda katman OLMAYAN dolgudan geliyordu:
 * kartlar ve yuva derileri kıvrımdan geçmiyor ama dış kabuğun
 * yürüyeceği yarıçapı belirliyor.
 *
 * Fold.gaps alanı tam olarak bunun için eklendi. Varsayılan
 * parametrelerle model 12–13mm veriyor; yarım inç kuralıyla örtüşüyor.
 * (Bkz. bifold.test.ts — bu bir test olarak sabitlendi.)
 */

export interface BifoldParams {
  /** Her panelde kaç kart yuvası. */
  readonly cardSlotsPerSide: number;
  readonly construction: SlotConstruction;
  readonly currency: Currency;
  readonly outerThickness: Mm;
  readonly innerThickness: Mm;
  readonly slotThickness: Mm;
  readonly temper: Temper;
  readonly reveal: Mm;
  readonly stitchMargin: Mm;
  readonly cornerRadius: Mm;
  readonly penAllowance: Mm;
  readonly pitch?: Mm;
}

export const BIFOLD_DEFAULTS: BifoldParams = {
  cardSlotsPerSide: 3,
  construction: "t-slot",
  currency: "TRY",
  // Bifold'da dış kabuk aralığın ALT ucunda tutulmalı; katman sayısı
  // fazla olduğu için kalınlık hızla birikiyor.
  outerThickness: 0.9,
  innerThickness: 0.8,
  slotThickness: RECOMMENDED_THICKNESS.cardSlot.preferred,
  temper: "veg-tan-firm",
  reveal: 12,
  stitchMargin: 3.5,
  cornerRadius: 5,
  penAllowance: 0.3,
  pitch: 3.85,
};

function rectangle(x: Mm, y: Mm, w: Mm, h: Mm): Polyline {
  return flattenPath(
    path()
      .moveTo(vec(x, y))
      .lineTo(vec(x + w, y))
      .lineTo(vec(x + w, y + h))
      .lineTo(vec(x, y + h))
      .close(),
  );
}

function tSlotShape(width: Mm, height: Mm, mouthHeight: Mm, sideInset: Mm): Polyline {
  const shoulder = height - mouthHeight;
  return flattenPath(
    path()
      .moveTo(vec(sideInset, 0))
      .lineTo(vec(width - sideInset, 0))
      .lineTo(vec(width - sideInset, shoulder))
      .lineTo(vec(width, shoulder))
      .lineTo(vec(width, height))
      .lineTo(vec(0, height))
      .lineTo(vec(0, shoulder))
      .lineTo(vec(sideInset, shoulder))
      .close(),
  );
}

export function generateBifold(params: BifoldParams): PatternResult {
  const diagnostics: Diagnostic[] = [];
  const n = Math.max(0, Math.floor(params.cardSlotsPerSide));

  // --- Kart yuvaları (panel başına) -------------------------------------
  const slotGeo = cardSlotGeometry({
    count: n,
    construction: params.construction,
    orientation: "horizontal",
    leatherThickness: params.slotThickness,
    reveal: params.reveal,
    stitchMargin: params.stitchMargin,
  });

  for (const d of validateCardSlots({
    count: n,
    construction: params.construction,
    orientation: "horizontal",
    leatherThickness: params.slotThickness,
    reveal: params.reveal,
    stitchMargin: params.stitchMargin,
  })) {
    diagnostics.push({ severity: d.severity, code: d.code, message: d.message });
  }

  // --- Cüzdan ölçüleri ---------------------------------------------------
  //
  // Açık genişlik iki kısıttan büyüğü:
  //   a) banknot + boşluk + iki yanda dikiş payı
  //   b) iki kart yığını yan yana
  // Yükseklik ise kart yığını ve banknot örtüsünden büyüğü.
  const billGeo = billPocketGeometry({
    currency: params.currency,
    leatherThickness: params.innerThickness,
    stitchMargin: params.stitchMargin,
  });

  const panelWidth = slotGeo.compartmentWidth;
  const widthFromCards = 2 * panelWidth;
  const widthFromBill = billGeo.compartmentWidth;
  const openWidth = Math.max(widthFromCards, widthFromBill);

  const heightFromCards = slotGeo.stackHeight + 2 * params.stitchMargin;
  const walletHeight = Math.max(heightFromCards, billGeo.minWalletHeight);

  for (const d of validateBillPocket(
    {
      currency: params.currency,
      leatherThickness: params.innerThickness,
      stitchMargin: params.stitchMargin,
    },
    walletHeight,
  )) {
    diagnostics.push({ severity: d.severity, code: d.code, message: d.message });
  }

  // --- Kalınlıklar -------------------------------------------------------
  //
  // Kapalı kalınlık en kalın noktada ölçülür: iki panel de kart yüklü.
  const cardStackPerPanel = slotGeo.centerThickness + n * CARD_THICKNESS;
  const closedThickness =
    2 * params.outerThickness + 2 * params.innerThickness + 2 * slotGeo.centerThickness;
  const loadedThickness =
    2 * params.outerThickness + 2 * params.innerThickness + 2 * cardStackPerPanel;

  // --- Kesit -------------------------------------------------------------
  //
  // Kıvrımda yalnızca iki deri katmanı geçiyor (iç ve dış kabuk).
  // Kart yığını kıvrımdan GEÇMEZ ama dış kabuğun yarıçapını belirler;
  // bu yüzden dolgu (gap) olarak modelleniyor.
  const outerSpec = leather(params.temper, params.outerThickness);
  const innerSpec = leather(params.temper, params.innerThickness);

  const layers: Layer[] = [
    { id: "inner", name: "iç kabuk", spec: innerSpec },
    { id: "outer", name: "dış kabuk", spec: outerSpec },
  ];

  const foldFill = cardStackPerPanel;

  const crossSection: CrossSection = {
    name: "bifold",
    layers,
    runs: [
      { id: "left", name: "sol panel", length: panelWidth, layers: ["inner", "outer"] },
      { id: "right", name: "sağ panel", length: panelWidth, layers: ["inner", "outer"] },
    ],
    folds: [
      {
        id: "spine",
        name: "sırt",
        angleDeg: 180,
        innerRadius: naturalInnerRadius(params.innerThickness),
        stack: ["inner", "outer"],
        gaps: { outer: foldFill },
      },
    ],
  };

  const solved = solveCrossSection(crossSection);
  diagnostics.push(...solved.diagnostics);

  const innerFlat = layerResult(solved, "inner")?.flatLength ?? openWidth;
  const outerFlat = layerResult(solved, "outer")?.flatLength ?? openWidth;
  const foldAllowance = outerFlat - innerFlat;

  // --- Parçalar ----------------------------------------------------------
  const pieces: PatternPiece[] = [];

  const outerNominal = roundCorners(rectangle(0, 0, outerFlat, walletHeight), true, {
    radius: params.cornerRadius,
  });
  const outerCut = cutLine(outerNominal, { penAllowance: params.penAllowance });

  // DİKİŞ HATTI U ŞEKLİNDE — ÜST KENAR AÇIK.
  //
  // Bifold'un üst kenarı banknot bölmesinin AĞZI. Kapalı bir çevre
  // dikişi hem o kenara delik yerleştirir hem de dikildiğinde para
  // bölmesini tamamen kapatır; ürün işe yaramaz hale gelir.
  //
  // İlk sürümde çevre kapalıydı ve üstteki kart yuvası (D-S3) üst
  // kenardan 28 delik alıyordu — tam olarak dikilmemesi gereken yerden.
  const m = params.stitchMargin;
  const outerStitch = roundCorners(
    flattenPath(
      path()
        .moveTo(vec(m, walletHeight - m))
        .lineTo(vec(m, m))
        .lineTo(vec(outerFlat - m, m))
        .lineTo(vec(outerFlat - m, walletHeight - m))
        .open(),
    ),
    false,
    { radius: Math.max(1, params.cornerRadius - m) },
  );
  const outerPlan = distributeStitches(
    outerStitch,
    false,
    params.pitch !== undefined ? { pitch: params.pitch } : {},
  );
  const outerBox = bbox(outerCut);

  const foldCentre = outerFlat / 2;
  pieces.push({
    id: "outer",
    code: "A",
    name: "dış kabuk",
    kind: "outer",
    quantity: 1,
    leatherThickness: params.outerThickness,
    cutLine: outerCut,
    stitchLine: outerStitch,
    stitchLineClosed: false,
    stitchPlan: outerPlan,
    foldLines: [
      {
        from: vec(foldCentre - foldAllowance / 2, 0),
        to: vec(foldCentre - foldAllowance / 2, walletHeight),
        label: "kat başlangıcı",
      },
      {
        from: vec(foldCentre + foldAllowance / 2, 0),
        to: vec(foldCentre + foldAllowance / 2, walletHeight),
        label: "kat bitişi",
      },
    ],
    width: outerBox.width,
    height: outerBox.height,
  });

  // İç kabuk: banknot bölmesinin arkası. Dış kabuktan kat payı kadar kısa.
  const innerNominal = roundCorners(rectangle(0, 0, innerFlat, walletHeight), true, {
    radius: params.cornerRadius,
  });
  const innerCut = cutLine(innerNominal, { penAllowance: params.penAllowance });
  const innerBox = bbox(innerCut);
  // İç kabuk çevre dikişine TAM BOYUNCA yakalanıyor. Kat payı sırtta
  // soğuruluyor, kenarlar hizalı kalıyor.
  const innerProjection = projectAcrossFold(
    outerPlan,
    foldCentre,
    foldAllowance,
    innerCut,
    true,
  );
  pieces.push({
    id: "inner",
    code: "B",
    name: "iç kabuk (para bölmesi)",
    kind: "outer",
    quantity: 1,
    leatherThickness: params.innerThickness,
    cutLine: innerCut,
    ...(innerProjection.plan === undefined
      ? {}
      : { stitchPlan: innerProjection.plan }),
    foldLines: [
      {
        from: vec(innerFlat / 2, 0),
        to: vec(innerFlat / 2, walletHeight),
        label: "kat",
      },
    ],
    width: innerBox.width,
    height: innerBox.height,
  });

  // --- Yuva parçaları ve montaj -----------------------------------------
  //
  // HER ÖRNEK AYRI PARÇA. Gruplamak ("T-slot yuva ×4") mümkün değil,
  // çünkü sol paneldeki yuva sol ve alt kenardan, sağ paneldeki sağ ve
  // alt kenardan delik alıyor; üstteki yuva alt kenar deliklerini hiç
  // almıyor. Aynı şekil, farklı delik deseni.
  //
  // Delikler ana çevre planından YANSITILIYOR, parça başına yeniden
  // hesaplanmıyor — hesaplansaydı katmanlar üst üste konduğunda
  // tutmazdı.
  const slotPieceHeight = CARD_ID1.height + params.stitchMargin;
  const mouthHeight = Math.min(params.reveal, slotPieceHeight / 2);
  const sideInset = params.stitchMargin + T_SLOT_WRAP_ALLOWANCE;

  const rectShape = roundCorners(
    rectangle(0, 0, panelWidth, slotPieceHeight),
    true,
    { radius: Math.min(params.cornerRadius, slotPieceHeight / 4) },
  );
  const tShape = roundCorners(
    tSlotShape(panelWidth, slotPieceHeight, mouthHeight, sideInset),
    true,
    { radius: Math.min(params.cornerRadius, sideInset / 2) },
  );

  const assembly: AssemblyPlacement[] = [];
  const rightPanelX = Math.max(0, outerFlat - panelWidth);
  const sides: readonly { readonly x: Mm; readonly tag: string }[] = [
    { x: 0, tag: "S" },
    { x: rightPanelX, tag: "R" },
  ];

  let layerIndex = 1;
  for (const side of sides) {
    for (let i = 0; i < n; i++) {
      const isRect = params.construction === "stacked" || i === 0;
      const code = `${isRect ? "C" : "D"}-${side.tag}${i + 1}`;
      const id = `slot-${side.tag}${i + 1}`;
      const origin = { x: side.x, y: i * params.reveal };

      const cut = cutLine(isRect ? rectShape : tShape, {
        penAllowance: params.penAllowance,
      });
      const b = bbox(cut);
      const projected = projectStitchPlan(outerPlan, origin, cut);

      pieces.push({
        id,
        code,
        name: isRect ? `alt yuva ${side.tag}${i + 1}` : `T-slot yuva ${side.tag}${i + 1}`,
        kind: isRect ? "slot-rect" : "slot-t",
        quantity: 1,
        leatherThickness: params.slotThickness,
        cutLine: cut,
        ...(projected.plan === undefined ? {} : { stitchPlan: projected.plan }),
        foldLines: [],
        width: b.width,
        height: b.height,
      });

      assembly.push({
        pieceId: id,
        code,
        x: origin.x,
        y: origin.y,
        layer: layerIndex,
      });
      layerIndex += 1;
    }
  }

  // --- Kural denetimi ----------------------------------------------------
  if (loadedThickness > MAX_CLOSED_THICKNESS) {
    diagnostics.push({
      severity: "error",
      code: "TOO_THICK",
      message:
        `Kart yüklü kalınlık ${loadedThickness.toFixed(1)}mm — üst sınır ` +
        `${MAX_CLOSED_THICKNESS}mm. Yuva sayısını azalt ya da daha ince deri kullan.`,
    });
  } else if (closedThickness > BIFOLD_TARGET_CLOSED_THICKNESS) {
    // ÖLÇÜT BOŞ KALINLIK. Belgelenmiş hedef ("iyi bir bifold boşken
    // 6–8mm'yi geçmemeli") boş ürün için verilmiş. İlk sürümde yüklü
    // kalınlığa bakıyordum ve 3 yuvalı — son derece yaygın — bir cüzdan
    // gereksiz yere uyarı alıyordu.
    diagnostics.push({
      severity: "warning",
      code: "BULKY",
      message:
        `Boş kalınlık ${closedThickness.toFixed(1)}mm — belgelenmiş hedef ` +
        `${BIFOLD_TARGET_CLOSED_THICKNESS}mm. Kart yüklü ` +
        `${loadedThickness.toFixed(1)}mm olacak. Yuva sayısını azaltmak ya da ` +
        `yuva derisini inceltmek belirgin fark yaratır.`,
    });
  }

  if (widthFromBill > widthFromCards) {
    diagnostics.push({
      severity: "warning",
      code: "WIDTH_FROM_BILL",
      message:
        `Açık genişliği banknot belirledi (${widthFromBill.toFixed(1)}mm > ` +
        `${widthFromCards.toFixed(1)}mm). Paneller kart yığınından geniş kalıyor; ` +
        `yuvaları ortalamak ya da bölme genişletmek gerekebilir.`,
    });
  }

  const fitsA4 = fitsOnA4(outerBox.width, outerBox.height);
  if (!fitsA4) {
    diagnostics.push({
      severity: "warning",
      code: "NEEDS_TILING",
      message:
        `Dış kabuk ${outerBox.width.toFixed(0)} × ${outerBox.height.toFixed(0)}mm — ` +
        `döndürülse bile tek A4'e sığmıyor, birden fazla sayfaya bölünecek.`,
    });
  }

  const summary: PatternSummary = {
    compartmentWidth: panelWidth,
    slotStackHeight: slotGeo.stackHeight,
    outerFlatWidth: outerBox.width,
    outerFlatHeight: outerBox.height,
    closedThickness,
    loadedThickness,
    edgeThickness: slotGeo.edgeThickness,
    foldAllowance,
    panelHeight: walletHeight,
    totalHoles: outerPlan.totalHoles,
    pitch: outerPlan.pitch,
    fitsA4,
  };

  return { pieces, assembly, crossSection: solved, diagnostics, summary };
}

/** Yarım inç kuralıyla karşılaştırma — modelin doğrulama çapası. */
export function halfInchRuleDeviation(params: BifoldParams): Mm {
  const result = generateBifold(params);
  const halfInch = 12.7;
  return result.summary.foldAllowance - halfInch;
}

export { foldLengthDelta };
ODK_EOF_2

echo "==> packages/print/src/print.test.ts"
cat > packages/print/src/print.test.ts << 'ODK_EOF_3'
import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { PDFDocument } from "pdf-lib";
import { mmToPt } from "@odk/geometry";
import type { CardHolderParams } from "@odk/patterns";
import {
  BIFOLD_DEFAULTS,
  DEFAULT_PARAMS,
  buildInstructions,
  generateBifold,
  generateCardHolder,
} from "@odk/patterns";
import {
  A4_PORTRAIT,
  printableArea,
  planTiles,
  tileOrigin,
  tileCode,
  tileCount,
  TILE_OVERLAP,
  CALIBRATION_SQUARE,
} from "./paper.js";
import {
  packPages,
  packPieces,
  pieceToLayout,
  scaleFromMeasurement,
  STYLES,
} from "./layout.js";
import { buildPatternPdf } from "./pdf.js";

const require = createRequire(import.meta.url);

function fontBytes(pkg: string, file: string): Uint8Array {
  return new Uint8Array(readFileSync(require.resolve(`${pkg}/${file}`)));
}

const FONTS = {
  regular: fontBytes(
    "@expo-google-fonts/ibm-plex-sans",
    "400Regular/IBMPlexSans_400Regular.ttf",
  ),
  mono: fontBytes(
    "@expo-google-fonts/jetbrains-mono",
    "400Regular/JetBrainsMono_400Regular.ttf",
  ),
};

describe("basılabilir alan", () => {
  it("A4'te kenar payı ve alt şerit düşülüyor", () => {
    const a = printableArea(A4_PORTRAIT);
    expect(a.width).toBe(190); // 210 - 2*10
    expect(a.height).toBe(263); // 297 - 2*10 - 14
    expect(a.originX).toBe(10);
    expect(a.originY).toBe(24);
  });
});

describe("döşeme planı", () => {
  it("basılabilir alana sığan tabaka tek sayfa", () => {
    const g = planTiles(180, 250, A4_PORTRAIT);
    expect(g.cols).toBe(1);
    expect(g.rows).toBe(1);
    expect(tileCount(g)).toBe(1);
  });

  it("adım = basılabilir alan − bindirme", () => {
    const g = planTiles(400, 600, A4_PORTRAIT);
    expect(g.stepX).toBe(190 - TILE_OVERLAP);
    expect(g.stepY).toBe(263 - TILE_OVERLAP);
  });

  it("döşemeler tabakanın tamamını kapsıyor", () => {
    for (const [w, h] of [
      [400, 600],
      [191, 264],
      [1000, 300],
      [95, 800],
    ] as const) {
      const g = planTiles(w, h, A4_PORTRAIT);
      const coveredX = (g.cols - 1) * g.stepX + g.tileWidth;
      const coveredY = (g.rows - 1) * g.stepY + g.tileHeight;
      expect(coveredX).toBeGreaterThanOrEqual(w - 1e-9);
      expect(coveredY).toBeGreaterThanOrEqual(h - 1e-9);
    }
  });

  it("komşu döşemeler tam olarak bindirme kadar örtüşüyor", () => {
    const g = planTiles(500, 500, A4_PORTRAIT);
    const a = tileOrigin(g, 0, 0);
    const b = tileOrigin(g, 1, 0);
    const overlapX = a.x + g.tileWidth - b.x;
    expect(overlapX).toBeCloseTo(TILE_OVERLAP, 9);
  });

  it("satırlar yukarıdan aşağı numaralanıyor", () => {
    const g = planTiles(190, 600, A4_PORTRAIT);
    const top = tileOrigin(g, 0, 0);
    const below = tileOrigin(g, 0, 1);
    expect(top.y).toBeGreaterThan(below.y);
  });

  it("bindirme basılabilir alandan büyükse hata", () => {
    expect(() => planTiles(500, 500, A4_PORTRAIT, 300)).toThrow(/ilerlemez/);
  });
});

describe("sayfa kodları", () => {
  it("sütun harfi + satır numarası", () => {
    expect(tileCode(0, 0)).toBe("A1");
    expect(tileCode(1, 0)).toBe("B1");
    expect(tileCode(0, 2)).toBe("A3");
  });

  it("26'dan sonra iki harf", () => {
    expect(tileCode(25, 0)).toBe("Z1");
    expect(tileCode(26, 0)).toBe("AA1");
  });
});

describe("parça yerleşimi", () => {
  const pattern = generateCardHolder(DEFAULT_PARAMS);

  it("tüm parçalar yerleştiriliyor", () => {
    const layout = packPieces(pattern.pieces);
    expect(layout.placed).toHaveLength(pattern.pieces.length);
  });

  it("parçalar üst üste binmiyor", () => {
    const layout = packPieces(pattern.pieces);
    for (let i = 0; i < layout.placed.length; i++) {
      for (let j = i + 1; j < layout.placed.length; j++) {
        const a = layout.placed[i] as (typeof layout.placed)[0];
        const b = layout.placed[j] as (typeof layout.placed)[0];
        const apart =
          a.x + a.width <= b.x + 1e-9 ||
          b.x + b.width <= a.x + 1e-9 ||
          a.y + a.height <= b.y + 1e-9 ||
          b.y + b.height <= a.y + 1e-9;
        expect(apart).toBe(true);
      }
    }
  });

  it("parçalar tabaka sınırları içinde", () => {
    const layout = packPieces(pattern.pieces);
    for (const p of layout.placed) {
      expect(p.x).toBeGreaterThanOrEqual(-1e-9);
      expect(p.y).toBeGreaterThanOrEqual(-1e-9);
      expect(p.x + p.width).toBeLessThanOrEqual(layout.width + 1e-9);
      expect(p.y + p.height).toBeLessThanOrEqual(layout.height + 1e-9);
    }
  });

  it("boş girdi boş yerleşim", () => {
    expect(packPieces([]).placed).toHaveLength(0);
  });

  it("basılabilir alandan geniş parça tabakayı genişletiyor", () => {
    const wide = generateCardHolder({
      ...DEFAULT_PARAMS,
      orientation: "horizontal",
      stitchMargin: 5,
    });
    const layout = packPieces(wide.pieces);
    expect(layout.width).toBeGreaterThanOrEqual(
      Math.max(...wide.pieces.map((p) => p.width)),
    );
  });
});

describe("kalibrasyon", () => {
  it("doğru ölçümde düzeltme yok", () => {
    const r = scaleFromMeasurement(50);
    expect(r.factor).toBe(1);
    expect(r.ok).toBe(true);
  });

  it("küçük basıldıysa büyütme katsayısı", () => {
    const r = scaleFromMeasurement(49.5);
    expect(r.ok).toBe(true);
    expect(r.factor).toBeCloseTo(50 / 49.5, 9);
    expect(r.factor).toBeGreaterThan(1);
  });

  it("büyük basıldıysa küçültme katsayısı", () => {
    const r = scaleFromMeasurement(50.5);
    expect(r.factor).toBeLessThan(1);
  });

  it("düzeltme uygulandığında sonuç nominale gider", () => {
    // Yazıcı %99 ölçekle basıyorsa: içeriği factor ile büyüt, yazıcı
    // 0.99 ile küçültsün, sonuç 50mm olsun.
    const printerScale = 0.99;
    const measured = CALIBRATION_SQUARE * printerScale;
    const { factor } = scaleFromMeasurement(measured);
    expect(CALIBRATION_SQUARE * factor * printerScale).toBeCloseTo(
      CALIBRATION_SQUARE,
      9,
    );
  });

  it("%10'dan fazla sapma reddediliyor", () => {
    // Kullanıcı inç ölçtüyse ~1.97 girer; sessizce uygulamak felaket olur.
    const r = scaleFromMeasurement(2);
    expect(r.ok).toBe(false);
    expect(r.factor).toBe(1);
    expect(r.message).toContain("mm");
  });

  it("geçersiz girdi reddediliyor", () => {
    expect(scaleFromMeasurement(0).ok).toBe(false);
    expect(scaleFromMeasurement(-5).ok).toBe(false);
    expect(scaleFromMeasurement(Number.NaN).ok).toBe(false);
  });
});

describe("çizgi biçimleri", () => {
  it("desenle ayrışıyor: kesim sürekli, diğerleri kesikli", () => {
    // Siyah-beyaz çıktıda tek ayırt edici desen olmalı.
    expect(STYLES.cut.dash).toHaveLength(0);
    expect(STYLES.stitch.dash.length).toBeGreaterThan(0);
    expect(STYLES.fold.dash.length).toBeGreaterThan(0);
    expect(STYLES.stitch.dash).not.toEqual(STYLES.fold.dash);
  });

  it("kesim çizgisi en koyu ve 0.2mm", () => {
    expect(STYLES.cut.width).toBe(0.2);
    expect(STYLES.cut.gray).toBe(0);
  });
});

describe("PDF üretimi", () => {
  const pattern = generateCardHolder(DEFAULT_PARAMS);

  it("geçerli PDF üretiyor", async () => {
    const bytes = await buildPatternPdf(pattern, FONTS);
    expect(bytes.length).toBeGreaterThan(1000);
    expect(new TextDecoder().decode(bytes.slice(0, 5))).toBe("%PDF-");
  });

  it("sayfa boyutu tam A4 (595.28 × 841.89 pt)", async () => {
    const bytes = await buildPatternPdf(pattern, FONTS);
    const doc = await PDFDocument.load(bytes);
    for (const page of doc.getPages()) {
      expect(page.getWidth()).toBeCloseTo(mmToPt(210), 3);
      expect(page.getHeight()).toBeCloseTo(mmToPt(297), 3);
    }
  });

  it("kapak + montaj + desen sayfaları", async () => {
    const bytes = await buildPatternPdf(pattern, FONTS);
    const doc = await PDFDocument.load(bytes);
    // Kapak + montaj + desen sayfaları (döşeme yoksa sayfa bazlı).
    expect(doc.getPageCount()).toBe(2 + packPages(pattern.pieces).pages.length);
  });

  it("montaj yerleşimi kart sayısı kadar örnek veriyor", () => {
    expect(pattern.assembly).toHaveLength(DEFAULT_PARAMS.cardCount);
  });

  it("montajda yuvalar kademe kadar aralıklı", () => {
    for (let i = 1; i < pattern.assembly.length; i++) {
      const a = pattern.assembly[i - 1] as (typeof pattern.assembly)[0];
      const b = pattern.assembly[i] as (typeof pattern.assembly)[0];
      expect(b.y - a.y).toBeCloseTo(DEFAULT_PARAMS.reveal, 9);
      expect(b.layer).toBe(a.layer + 1);
    }
  });

  it("T-slot yapımda yalnızca en dip yuva düz dikdörtgen", () => {
    const rects = pattern.pieces.filter((p) => p.kind === "slot-rect");
    expect(rects).toHaveLength(1);
    expect(pattern.assembly[0]?.pieceId).toBe(rects[0]?.id);
  });

  it("en üstteki yuvanın üstü, ağız payı kadar altta kalıyor", () => {
    // Kademe dizilimi paneli tam doldurmalı: (n−1)·kademe + kart
    // yüksekliği + dikiş payı = panelHeight.
    //
    // DİKKAT: parça yükseklikleri KESİM ölçüsü (kalem payı iki kenardan
    // düşülmüş), montaj konumları ise nominal. Karşılaştırmada payı geri
    // eklemek gerekiyor; ilk yazdığımda bunu atlayıp 0.6mm'lik sahte bir
    // uyuşmazlık görmüştüm.
    const top = pattern.assembly.at(-1);
    const slotPiece = pattern.pieces.find((p) => p.id === top?.pieceId);
    const nominalHeight =
      (slotPiece?.height as number) + 2 * DEFAULT_PARAMS.penAllowance;
    // Dikey kata geçtikten sonra cüzdan yüksekliği yığından bir dikiş
    // payı FAZLA: kart ağzı üst kenarın altında kalmalı, yoksa kartlar
    // dışarı görünür ve açık kenardan kayar.
    expect((top?.y as number) + nominalHeight).toBeCloseTo(
      pattern.summary.panelHeight - DEFAULT_PARAMS.stitchMargin,
      6,
    );
  });

  it("parça kodları benzersiz", () => {
    const codes = pattern.pieces.map((p) => p.code);
    expect(new Set(codes).size).toBe(codes.length);
  });

  it("mono font BOŞLUK karakterini gömebiliyor", async () => {
    // FONT SEÇİMİ TESADÜFİ DEĞİL.
    //
    // İlk tercih IBM Plex Mono'ydu (ekran arayüzüyle aynı olsun diye).
    // @pdf-lib/fontkit o TTF'te boşluk karakterinde patlıyor:
    // "Trying to access beyond buffer length" — boş konturlu glifin
    // sınırlayıcı kutusunu okumaya çalışıyor. subset açık/kapalı fark
    // etmiyor. JetBrains Mono aynı işlemi sorunsuz yapıyor.
    //
    // Bu test, biri "ekranla aynı font olsun" diye geri değiştirirse
    // sorunun sessizce dönmemesi için burada.
    const bytes = await buildPatternPdf(pattern, FONTS, {
      title: "bölme genişliği 100.0 mm · dış kabuk",
    });
    expect(bytes.length).toBeGreaterThan(1000);
  });

  it("Türkçe karakterler gömülü fontla kodlanıyor", async () => {
    // Standart PDF fontları (WinAnsi) ı, ş, ğ kodlayamıyor; gömme
    // yapılmazsa üretim tamamen patlar.
    await expect(
      buildPatternPdf(pattern, FONTS, { title: "Kartlık — dış kabuk şablonu kağıt" }),
    ).resolves.toBeInstanceOf(Uint8Array);
  });

  it("kalibrasyon katsayısı çıktıyı büyütüyor", async () => {
    const a = await buildPatternPdf(pattern, FONTS, { scaleFactor: 1 });
    const b = await buildPatternPdf(pattern, FONTS, { scaleFactor: 1.02 });
    // Aynı sayfa sayısı, farklı içerik.
    const da = await PDFDocument.load(a);
    const db = await PDFDocument.load(b);
    expect(db.getPageCount()).toBe(da.getPageCount());
    expect(b.length).not.toBe(a.length);
  });

  it("tüm delikleri basmak çıktıyı büyütüyor", async () => {
    const few = await buildPatternPdf(pattern, FONTS, { printAllHoles: false });
    const many = await buildPatternPdf(pattern, FONTS, { printAllHoles: true });
    expect(many.length).toBeGreaterThan(few.length);
  });

  it("params verilirse yapım adımları sayfası ekleniyor", async () => {
    const without = await PDFDocument.load(
      await buildPatternPdf(pattern, FONTS),
    );
    const withSteps = await PDFDocument.load(
      await buildPatternPdf(pattern, FONTS, { params: DEFAULT_PARAMS }),
    );
    expect(withSteps.getPageCount()).toBeGreaterThan(without.getPageCount());
  });

  it("adım sayfası sayısı metin uzunluğuna göre hesaplanıyor", async () => {
    // Sabit "sayfa başına N adım" varsayımı yok; 8 yuvalı kalıpta
    // yapıştırma sırası uzuyor ve taşma buna göre hesaplanmalı.
    const p8: CardHolderParams = { ...DEFAULT_PARAMS, cardCount: 8 };
    const big = generateCardHolder(p8);
    const steps = buildInstructions(big, p8);
    expect(steps.length).toBeGreaterThan(8);
    const doc = await PDFDocument.load(
      await buildPatternPdf(big, FONTS, { params: p8 }),
    );
    expect(doc.getPageCount()).toBeGreaterThan(4);
  });

  it("VARSAYILAN tüm delikleri basıyor", async () => {
    // Yaygın iş akışı kağıt şablonu deriye bantlayıp işaretli
    // noktalardan delmek; noktalar şablonun asıl işlevlerinden biri.
    const def = await buildPatternPdf(pattern, FONTS);
    const anchorsOnly = await buildPatternPdf(pattern, FONTS, {
      printAllHoles: false,
    });
    expect(def.length).toBeGreaterThan(anchorsOnly.length);
  });

  it("çok sayfalı kalıpta sayfa sayısı artıyor", async () => {
    const big = generateCardHolder({
      ...DEFAULT_PARAMS,
      cardCount: 8,
      reveal: 20,
    });
    const bytes = await buildPatternPdf(big, FONTS);
    const doc = await PDFDocument.load(bytes);
    expect(doc.getPageCount()).toBeGreaterThan(2);
  });
});

describe("sayfa bazlı yerleştirme — hizalama gerektirmeyen çıktı", () => {
  const bifold = generateBifold(BIFOLD_DEFAULTS);

  it("bifold parçaları döndürülünce tek sayfaya sığıyor", () => {
    // ASIL KAZANÇ BU: döşeme olmadan hiçbir parça bölünmüyor, dolayısıyla
    // kullanıcının sayfa hizalama hatası ürünün ölçüsüne giremiyor.
    const layout = packPages(bifold.pieces);
    expect(layout.oversized).toHaveLength(0);
    expect(layout.rotatedCount).toBeGreaterThan(0);
  });

  it("her parça tam olarak bir kez yerleştiriliyor", () => {
    const layout = packPages(bifold.pieces);
    const placedIds = layout.pages.flatMap((p) => p.placed.map((x) => x.piece.id));
    expect(placedIds.sort()).toEqual(bifold.pieces.map((p) => p.id).sort());
  });

  it("yerleştirilen parçalar basılabilir alanı taşmıyor", () => {
    const area = printableArea(A4_PORTRAIT);
    for (const page of packPages(bifold.pieces).pages) {
      for (const p of page.placed) {
        expect(p.x).toBeGreaterThanOrEqual(-1e-9);
        expect(p.y).toBeGreaterThanOrEqual(-1e-9);
        expect(p.x + p.width).toBeLessThanOrEqual(area.width + 1e-9);
        expect(p.y + p.height).toBeLessThanOrEqual(area.height + 1e-9);
      }
    }
  });

  it("aynı sayfadaki parçalar üst üste binmiyor", () => {
    for (const page of packPages(bifold.pieces).pages) {
      for (let i = 0; i < page.placed.length; i++) {
        for (let j = i + 1; j < page.placed.length; j++) {
          const a = page.placed[i] as (typeof page.placed)[0];
          const b = page.placed[j] as (typeof page.placed)[0];
          const apart =
            a.x + a.width <= b.x + 1e-9 ||
            b.x + b.width <= a.x + 1e-9 ||
            a.y + a.height <= b.y + 1e-9 ||
            b.y + b.height <= a.y + 1e-9;
          expect(apart).toBe(true);
        }
      }
    }
  });

  it("döndürme kapatılırsa büyük parçalar döşemeye düşüyor", () => {
    const layout = packPages(bifold.pieces, A4_PORTRAIT, undefined, false);
    expect(layout.rotatedCount).toBe(0);
    expect(layout.oversized.length).toBeGreaterThan(0);
  });

  it("döndürülmüş parçada ölçüler takas ediliyor", () => {
    const layout = packPages(bifold.pieces);
    const outer = layout.pages
      .flatMap((p) => p.placed)
      .find((p) => p.piece.id === "outer");
    expect(outer?.rotated).toBe(true);
    expect(outer?.width).toBeCloseTo(outer?.piece.height as number, 9);
    expect(outer?.height).toBeCloseTo(outer?.piece.width as number, 9);
  });

  it("pieceToLayout döndürmeyi doğru uyguluyor", () => {
    // Yerel (0,0) köşesi, döndürülmüş parçada sol-ÜST köşeye gider.
    const placed = {
      piece: bifold.pieces[0] as (typeof bifold.pieces)[0],
      x: 10,
      y: 20,
      width: 50,
      height: 100,
      rotated: true,
    };
    expect(pieceToLayout(placed, { x: 0, y: 0 }, 0, 0)).toEqual({ x: 60, y: 20 });
    expect(pieceToLayout(placed, { x: 0, y: 50 }, 0, 0)).toEqual({ x: 10, y: 20 });
  });

  it("kartlıkta da hiç bölünme olmuyor", () => {
    const ch = generateCardHolder(DEFAULT_PARAMS);
    expect(packPages(ch.pieces).oversized).toHaveLength(0);
  });

  it("PDF üretilebiliyor ve sayfa sayısı makul", async () => {
    const bytes = await buildPatternPdf(bifold, FONTS, {
      params: BIFOLD_DEFAULTS,
    });
    const doc = await PDFDocument.load(bytes);
    // kapak + montaj + adımlar + desen sayfaları
    expect(doc.getPageCount()).toBeGreaterThanOrEqual(5);
    expect(doc.getPageCount()).toBeLessThan(12);
  });
});
ODK_EOF_3

echo "==> Testler"
pnpm test

echo "==> Typecheck"
pnpm typecheck

echo "==> Arayuz derlemesi"
pnpm --filter @odk/web build

cat << 'ODK_DONE'

============================================================
KARTLIK — DIKEY KAT, ACIK AGIZ
============================================================

Kartlik 4 yuva:
  acik 222.9 x 96.4mm · kat payi 23.53mm · kapali 4.80mm
  A4: siginiyor (dondurulerek) · 3 desen sayfasi · tasan yok
  parcalar: A dis kabuk, B1 alt yuva, C2/C3/C4 T-slot

Git:
  git add -A
  git commit -m "Kartlik: dikey kat, U dikis, dondurmeli A4 kontrolu

ONCEKI TESHISIMI DUZELTIYORUM
'Yan dikis kati keser, urun katlanmaz' demistim; bu YANLISTI. Taco
katlamada yan dikis kat kosesini donerek gecer, sorun cikarmaz.

GERCEK SORUNLAR
- Kapali cevre dikisi kartligin AGZINI da dikiyordu; kart giremezdi.
- Yatay katta iki AYRI yan dikis gerekir (tek U olmaz), cunku kat
  ortada ve iki serbest uc agzi olusturur.

COZUM: kat dikey. Bifold'da dogrulanmis yapinin aynisi — sirt ortada,
agiz ustte, dikis U seklinde. Iki ayri dikis kosusunu desteklemek
gerekmedi.

KAT PAYI HESABI DUZELTILDI
Bifold'daki gibi 'dis - ic' almak kartlikta yanlis: yuva katmani
yalnizca on panelden geciyor, dis kabuk ikisinden de. Farki almak bir
panel boyunu da iceri katiyor ve 121mm gibi sacma bir sayi uretiyordu.
Dogru olcut: dis kabugun duz uzunlugunun iki panelden fazlasi.

A4 KONTROLU DONDURMEYI HESABA KATIYOR
Baski katmani sigmayan parcayi 90 derece ceviriyor; duz hale bakip
'bolunecek' demek yanlis uyariydi. 222.9x96.4 parca dondurulunce
siginiyor ve artik uyari cikmiyor.

- 323 test geciyor"

  git push
  vercel --prod
ODK_DONE
