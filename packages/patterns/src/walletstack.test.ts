import { describe, expect, it } from "vitest";
import {
  BIFOLD_DEFAULTS,
  generateBifold,
  halfInchRuleDeviation,
} from "./bifold.js";
import {
  MAX_PANEL_SLOTS,
  WALLET_STACK_DEFAULTS,
  compileToBifoldParams,
  generateFromStack,
  stackContributions,
  validateStack,
  withSlotCount,
} from "./walletstack.js";

describe("modül yığını — derleme", () => {
  it("varsayılan yığın BIFOLD_DEFAULTS'a birebir derleniyor", () => {
    // Boş builder = mevcut varsayılan bifold. Çapaların yığın yolundan
    // da geçtiğinin ön koşulu bu.
    expect(compileToBifoldParams(WALLET_STACK_DEFAULTS)).toEqual(BIFOLD_DEFAULTS);
  });

  it("yuva sayısını ve banknotu doğru taşıyor", () => {
    const stack = withSlotCount(WALLET_STACK_DEFAULTS, 5);
    const p = compileToBifoldParams({
      ...stack,
      spine: { kind: "billPocket", currency: "USD" },
    });
    expect(p.cardSlotsPerSide).toBe(5);
    expect(p.currency).toBe("USD");
  });

  it("withSlotCount 0..MAX aralığına kısıtlıyor", () => {
    expect(withSlotCount(WALLET_STACK_DEFAULTS, -3).slots).toHaveLength(0);
    expect(withSlotCount(WALLET_STACK_DEFAULTS, 99).slots).toHaveLength(
      MAX_PANEL_SLOTS,
    );
    expect(withSlotCount(WALLET_STACK_DEFAULTS, 4).slots).toHaveLength(4);
  });

  it("generateFromStack, derlenmiş paramla üretilen kalıpla aynı", () => {
    const stack = withSlotCount(WALLET_STACK_DEFAULTS, 4);
    const viaStack = generateFromStack(stack);
    const viaParams = generateBifold(compileToBifoldParams(stack));
    expect(viaStack.summary.foldAllowance).toBeCloseTo(
      viaParams.summary.foldAllowance,
      9,
    );
    expect(viaStack.summary.outerFlatWidth).toBeCloseTo(
      viaParams.summary.outerFlatWidth,
      9,
    );
    expect(viaStack.pieces).toHaveLength(viaParams.pieces.length);
  });
});

describe("modül yığını — katkı bütünlüğü", () => {
  it("yığın kalınlığı çözücü özetiyle birebir", () => {
    for (const n of [0, 1, 2, 3, 5]) {
      const stack = withSlotCount(WALLET_STACK_DEFAULTS, n);
      const c = stackContributions(stack);
      const s = generateFromStack(stack).summary;
      expect(c.closedThickness).toBeCloseTo(s.closedThickness, 6);
      expect(c.loadedThickness).toBeCloseTo(s.loadedThickness, 6);
    }
  });

  it("modül yükseklikleri panel yığın yüksekliğini topluyor", () => {
    const stack = withSlotCount(WALLET_STACK_DEFAULTS, 4);
    const c = stackContributions(stack);
    const slotHeights = c.modules
      .filter((m) => m.label.startsWith("Kart yuvası"))
      .reduce((a, m) => a + m.height, 0);
    expect(slotHeights).toBeCloseTo(c.perPanelStackHeight, 6);
  });
});

describe("modül yığını — çapalar korunuyor", () => {
  it("2 yuvalı yığın yarım inç kuralını sağlıyor", () => {
    // MAKESUPPLY: bare-minimum bifold (2 yuva) yığın yolundan geçince de
    // yarım inçe (12.7mm) yakın kalmalı.
    const stack = withSlotCount(WALLET_STACK_DEFAULTS, 2);
    const dev = Math.abs(halfInchRuleDeviation(compileToBifoldParams(stack)));
    expect(dev).toBeLessThan(1.5);
  });

  it("varsayılan yığının açık ölçüsü ticari mertebede", () => {
    const r = generateFromStack(WALLET_STACK_DEFAULTS);
    expect(r.summary.outerFlatWidth).toBeGreaterThan(190);
    expect(r.summary.outerFlatWidth).toBeLessThan(240);
  });

  it("varsayılan yığında yatay bölme ~100mm", () => {
    const c = stackContributions(WALLET_STACK_DEFAULTS);
    expect(c.compartmentWidth).toBeGreaterThan(95);
    expect(c.compartmentWidth).toBeLessThan(105);
  });
});

describe("modül yığını — kural motoru", () => {
  it("boş yığın kart yuvası uyarısı veriyor", () => {
    const diags = validateStack(withSlotCount(WALLET_STACK_DEFAULTS, 0));
    expect(diags.some((d) => d.code === "STACK_NO_SLOTS")).toBe(true);
  });

  it("aşırı kalın yığın hata veriyor", () => {
    const thick = {
      ...withSlotCount(WALLET_STACK_DEFAULTS, MAX_PANEL_SLOTS),
      settings: {
        ...WALLET_STACK_DEFAULTS.settings,
        slotThickness: 1.0,
        outerThickness: 1.4,
        innerThickness: 1.2,
      },
    };
    const diags = validateStack(thick);
    const err = diags.find((d) => d.code === "STACK_TOO_THICK");
    expect(err?.severity).toBe("error");
  });

  it("makul yığın hata üretmiyor", () => {
    const diags = validateStack(withSlotCount(WALLET_STACK_DEFAULTS, 3));
    expect(diags.some((d) => d.severity === "error")).toBe(false);
  });
});
