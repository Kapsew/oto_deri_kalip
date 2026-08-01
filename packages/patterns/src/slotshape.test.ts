import { describe, it, expect } from "vitest";
import type { Vec } from "@odk/geometry";
import { bbox, flattenPath, path, vec } from "@odk/geometry";
import { SLOT_SHAPES, slotShapePath } from "./slotshape.js";
import { BIFOLD_DEFAULTS, generateBifold } from "./bifold.js";

const dims = { width: 100, height: 58, mouthHeight: 12, sideInset: 6.5 };

/** Kapalı poligonun mutlak alanı (shoelace) — geçerlilik ölçütü. */
function area(poly: readonly Vec[]): number {
  let a = 0;
  for (let i = 0; i < poly.length; i++) {
    const p = poly[i] as Vec;
    const q = poly[(i + 1) % poly.length] as Vec;
    a += p.x * q.y - q.x * p.y;
  }
  return Math.abs(a) / 2;
}

describe("slotShapePath — mevcut şekillerle BİREBİR", () => {
  it("duz = eski rectangle(0,0,w,h)", () => {
    const { width: w, height: h } = dims;
    const expected = flattenPath(
      path()
        .moveTo(vec(0, 0))
        .lineTo(vec(w, 0))
        .lineTo(vec(w, h))
        .lineTo(vec(0, h))
        .close(),
    );
    expect(slotShapePath("duz", dims)).toEqual(expected);
  });

  it("t-slot = eski tSlotShape", () => {
    const { width: w, height: h, mouthHeight, sideInset: si } = dims;
    const shoulder = h - mouthHeight;
    const expected = flattenPath(
      path()
        .moveTo(vec(si, 0))
        .lineTo(vec(w - si, 0))
        .lineTo(vec(w - si, shoulder))
        .lineTo(vec(w, shoulder))
        .lineTo(vec(w, h))
        .lineTo(vec(0, h))
        .lineTo(vec(0, shoulder))
        .lineTo(vec(si, shoulder))
        .close(),
    );
    expect(slotShapePath("t-slot", dims)).toEqual(expected);
  });
});

describe("slotShapePath — yeni ağız şekilleri geçerli", () => {
  for (const id of ["kavis", "oyuk", "acili"] as const) {
    it(`${id}: kapalı, alanı pozitif, sınır kutusu içinde`, () => {
      const poly = slotShapePath(id, dims);
      expect(poly.length).toBeGreaterThanOrEqual(4);
      expect(area(poly)).toBeGreaterThan(0);
      const b = bbox(poly);
      expect(b.min.x).toBeGreaterThanOrEqual(-1e-6);
      expect(b.min.y).toBeGreaterThanOrEqual(-1e-6);
      expect(b.max.x).toBeLessThanOrEqual(dims.width + 1e-6);
      expect(b.max.y).toBeLessThanOrEqual(dims.height + 1e-6);
    });
  }

  it("yeni şekiller düz t-slot'tan farklı hat üretir", () => {
    const t = slotShapePath("t-slot", dims);
    expect(slotShapePath("kavis", dims)).not.toEqual(t);
    expect(slotShapePath("oyuk", dims)).not.toEqual(t);
    expect(slotShapePath("acili", dims)).not.toEqual(t);
  });
});

describe("SLOT_SHAPES kataloğu", () => {
  it("her sunulan şekil kataloğda var", () => {
    const ids = SLOT_SHAPES.map((s) => s.id);
    for (const id of ["t-slot", "kavis", "oyuk", "acili"]) {
      expect(ids).toContain(id);
    }
  });

  it("hepsi omuzlu (kenar tek katman kalır)", () => {
    expect(SLOT_SHAPES.every((s) => s.hasShoulders)).toBe(true);
  });
});

describe("bifold — slotShape YALNIZCA yerel şekli değiştirir", () => {
  const base = generateBifold(BIFOLD_DEFAULTS);
  const shaped = generateBifold({ ...BIFOLD_DEFAULTS, slotShape: "oyuk" });

  it("özet metrikleri (kat payı, ölçü, kalınlık) değişmez", () => {
    // Ağız şekli gövdeyi/kesiti etkilemez — kalıbın matematiği sabit.
    expect(shaped.summary.foldAllowance).toBeCloseTo(base.summary.foldAllowance, 9);
    expect(shaped.summary.outerFlatWidth).toBeCloseTo(
      base.summary.outerFlatWidth,
      9,
    );
    expect(shaped.summary.closedThickness).toBeCloseTo(
      base.summary.closedThickness,
      9,
    );
  });

  it("parça kodları aynı ama üst yuva hattı farklı", () => {
    expect(shaped.pieces.map((p) => p.code)).toEqual(
      base.pieces.map((p) => p.code),
    );
    const baseD = base.pieces.find((p) => p.code === "D-S2");
    const shapedD = shaped.pieces.find((p) => p.code === "D-S2");
    expect(shapedD?.cutLine).not.toEqual(baseD?.cutLine);
  });

  it("varsayılan (slotShape yok) çıktısı t-slot ile birebir", () => {
    const explicit = generateBifold({ ...BIFOLD_DEFAULTS, slotShape: "t-slot" });
    expect(explicit.pieces.map((p) => p.code)).toEqual(
      base.pieces.map((p) => p.code),
    );
    const b = base.pieces.find((p) => p.code === "D-S2");
    const e = explicit.pieces.find((p) => p.code === "D-S2");
    expect(e?.cutLine).toEqual(b?.cutLine);
  });

  it("hata üretmiyor", () => {
    expect(shaped.diagnostics.filter((d) => d.severity === "error")).toHaveLength(
      0,
    );
  });
});
