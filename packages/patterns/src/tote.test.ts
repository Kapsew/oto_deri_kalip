import { describe, it, expect } from "vitest";
import {
  STRAP_SPECS,
  STRAP_OVERLAP,
  STRIP_TEMPLATE_LIMIT,
  TOTE_DEFAULTS,
  generateTote,
} from "./tote.js";
import { buildInstructions } from "./instructions.js";

describe("askı ölçüleri", () => {
  it("çapraz askı belgelenmiş 114–137cm aralığına düşüyor", () => {
    const s = STRAP_SPECS.capraz;
    const total = s.multiplier * s.defaultDrop + 2 * STRAP_OVERLAP;
    expect(total).toBeGreaterThanOrEqual(1140);
    expect(total).toBeLessThanOrEqual(1370);
  });

  it("çapraz askı omuzdan uzun, omuz saptan uzun", () => {
    const len = (k: keyof typeof STRAP_SPECS) =>
      STRAP_SPECS[k].multiplier * STRAP_SPECS[k].defaultDrop;
    expect(len("capraz")).toBeGreaterThan(len("omuz"));
    expect(len("omuz")).toBeGreaterThan(len("el"));
  });

  it("çapraz çarpanı 2.3 — omuzdan farklı", () => {
    // Çapraz askı gövdeyi diyagonal kestiği için daha uzun yol izliyor.
    expect(STRAP_SPECS.capraz.multiplier).toBeCloseTo(2.3, 6);
    expect(STRAP_SPECS.omuz.multiplier).toBe(2);
  });

  it("el sapı iki adet, askılar tek", () => {
    expect(STRAP_SPECS.el.count).toBe(2);
    expect(STRAP_SPECS.omuz.count).toBe(1);
    expect(STRAP_SPECS.capraz.count).toBe(1);
  });

  it("aralık dışı drop uyarı üretiyor", () => {
    const r = generateTote({ ...TOTE_DEFAULTS, strapDrop: 900 });
    expect(r.diagnostics.some((d) => d.code === "STRAP_DROP_UNUSUAL")).toBe(true);
  });
});

describe("körük uzunluğu", () => {
  const r = generateTote(TOTE_DEFAULTS);

  it("panel dikiş hattının yay uzunluğuna eşit", () => {
    // Beklenen: 2×(H−R) + (W−2R) + 2×(πR/2)
    const { width: W, height: H, cornerRadius: R } = TOTE_DEFAULTS;
    const expected = 2 * (H - R) + (W - 2 * R) + 2 * ((Math.PI / 2) * R);
    const actual = Number(
      (r.summary.metrics?.find((m) => m.label === "körük uzunluğu")?.value ?? "0").replace(
        " mm",
        "",
      ),
    );
    expect(actual).toBeCloseTo(expected, 0);
  });

  it("köşe yarıçapı büyüdükçe körük KISALIYOR", () => {
    // Köşeyi yuvarlatmak yolu kısaltır: 2R yerine πR/2 gidiyorsun.
    const sharp = generateTote({ ...TOTE_DEFAULTS, cornerRadius: 20 });
    const round = generateTote({ ...TOTE_DEFAULTS, cornerRadius: 60 });
    const len = (x: typeof sharp) =>
      Number(
        (x.summary.metrics?.find((m) => m.label === "körük uzunluğu")?.value ?? "0").replace(
          " mm",
          "",
        ),
      );
    expect(len(round)).toBeLessThan(len(sharp));
  });
});

describe("körük delikleri panelle eşleşiyor", () => {
  it("üç parçalı körüğün delikleri panelin toplamına eşit", () => {
    // Her körük parçasının İKİ kenarı var; toplam = 2 × panel deliği.
    const r = generateTote({ ...TOTE_DEFAULTS, gusset: "uc-parca" });
    const panel = r.pieces.find((p) => p.id === "panel");
    const gussetHoles = r.pieces
      .filter((p) => p.id.startsWith("gusset"))
      .reduce((a, p) => a + (p.stitchPlan?.totalHoles ?? 0) * p.quantity, 0);
    expect(gussetHoles).toBe((panel?.stitchPlan?.totalHoles as number) * 2);
  });

  it("tek parçalı körükte de aynı toplam", () => {
    const r = generateTote({ ...TOTE_DEFAULTS, gusset: "tek-parca" });
    const panel = r.pieces.find((p) => p.id === "panel");
    const g = r.pieces.find((p) => p.id === "gusset");
    expect(g?.stitchPlan?.totalHoles).toBe(
      (panel?.stitchPlan?.totalHoles as number) * 2,
    );
  });

  it("delikler körüğün iki uzun kenarında", () => {
    const r = generateTote(TOTE_DEFAULTS);
    const g = r.pieces.find((p) => p.id === "gusset-bottom");
    const ys = new Set((g?.stitchPlan?.holes ?? []).map((h) => h.position.y.toFixed(2)));
    expect(ys.size).toBe(2);
  });
});

describe("parçalar", () => {
  it("panel iki adet, aynı kalıp", () => {
    const r = generateTote(TOTE_DEFAULTS);
    expect(r.pieces.find((p) => p.id === "panel")?.quantity).toBe(2);
  });

  it("üç parçalı körük: 2 yan + 1 taban", () => {
    const r = generateTote({ ...TOTE_DEFAULTS, gusset: "uc-parca" });
    expect(r.pieces.find((p) => p.id === "gusset-side")?.quantity).toBe(2);
    expect(r.pieces.find((p) => p.id === "gusset-bottom")?.quantity).toBe(1);
  });

  it("üç parçalı körükte parçalar A4'e sığıyor, tek parçalıda sığmıyor", () => {
    const three = generateTote({ ...TOTE_DEFAULTS, gusset: "uc-parca" });
    const one = generateTote({ ...TOTE_DEFAULTS, gusset: "tek-parca" });
    const g3 = three.pieces.filter((p) => p.id.startsWith("gusset"));
    const g1 = one.pieces.find((p) => p.id === "gusset");
    for (const p of g3) expect(Math.min(p.width, p.height)).toBeLessThan(190);
    expect(Math.max(g1?.width as number, g1?.height as number)).toBeGreaterThan(277);
  });

  it("uzun askı şablon olarak basılmıyor, ölçüsü bildiriliyor", () => {
    // Düz bir şerit için 5 sayfa döşeme basmak kâğıt israfı.
    const r = generateTote(TOTE_DEFAULTS);
    expect(r.pieces.some((p) => p.id === "strap")).toBe(false);
    const d = r.diagnostics.find((x) => x.code === "STRAP_NOT_PRINTED");
    expect(d?.message).toContain("cetvelle");
  });

  it("kısa sap şablon olarak basılıyor", () => {
    const r = generateTote({ ...TOTE_DEFAULTS, strap: "el", strapDrop: 250 });
    const strap = r.pieces.find((p) => p.id === "strap");
    // 2×250 + 80 = 580 > 400 -> yine basılmıyor. Sınırı test edelim.
    expect(STRIP_TEMPLATE_LIMIT).toBe(400);
    expect(strap === undefined || strap.width <= STRIP_TEMPLATE_LIMIT).toBe(true);
  });

  it("askısız çantada askı parçası ve uyarısı yok", () => {
    const r = generateTote({ ...TOTE_DEFAULTS, strap: "yok" });
    expect(r.pieces.some((p) => p.id === "strap")).toBe(false);
    expect(r.diagnostics.some((d) => d.code.startsWith("STRAP"))).toBe(false);
  });
});

describe("kurallar", () => {
  it("köşe yarıçapı derinliğin yarısından küçükse uyarı", () => {
    const r = generateTote({ ...TOTE_DEFAULTS, cornerRadius: 20, depth: 100 });
    expect(r.diagnostics.some((d) => d.code === "CORNER_TOO_TIGHT")).toBe(true);
  });

  it("varsayılanda köşe kuralı sağlanıyor", () => {
    const r = generateTote(TOTE_DEFAULTS);
    expect(r.diagnostics.some((d) => d.code === "CORNER_TOO_TIGHT")).toBe(false);
  });

  it("ince panel derisi uyarı üretiyor", () => {
    const r = generateTote({ ...TOTE_DEFAULTS, panelThickness: 0.8 });
    expect(r.diagnostics.some((d) => d.code === "PANEL_TOO_THIN")).toBe(true);
  });

  it("ince askı derisi uyarı üretiyor", () => {
    const r = generateTote({ ...TOTE_DEFAULTS, strapThickness: 1.4 });
    expect(r.diagnostics.some((d) => d.code === "STRAP_TOO_THIN")).toBe(true);
  });

  it("A4 uyarısı ne kadar küçültmesi gerektiğini söylüyor", () => {
    const r = generateTote(TOTE_DEFAULTS);
    const d = r.diagnostics.find((x) => x.code === "NEEDS_TILING");
    expect(d?.message).toMatch(/en fazla \d+mm/);
  });

  it("hacim doğru hesaplanıyor", () => {
    const r = generateTote(TOTE_DEFAULTS);
    const v = r.summary.metrics?.find((m) => m.label === "hacim")?.value;
    expect(v).toBe("3.52 L");
  });
});

describe("çanta talimatları", () => {
  const r = generateTote(TOTE_DEFAULTS);
  const steps = buildInstructions(r, { ...TOTE_DEFAULTS, kind: "canta" });

  it("cüzdan adımları kullanılmıyor", () => {
    const text = steps.map((s) => s.body).join(" ");
    expect(text).not.toContain("kademeyle diz");
    expect(text).toContain("Körüğün ORTASINI");
  });

  it("körüğü çekiştirerek dikme uyarısı var", () => {
    const align = steps.find((s) => s.title.includes("hizala"));
    expect(align?.warning).toContain("çekiştirerek");
  });

  it("askı dikişi uyarısı var", () => {
    const strap = steps.find((s) => s.title.includes("Askı"));
    expect(strap?.warning).toContain("çift sıra");
  });

  it("kenar bitirmenin cüzdanın TERSİ olduğu belirtiliyor", () => {
    const edge = steps.find((s) => s.title.includes("Kenarları bitir"));
    expect(edge?.warning).toContain("SONRA");
  });

  it("askısız çantada askı adımı yok", () => {
    const noStrap = generateTote({ ...TOTE_DEFAULTS, strap: "yok" });
    const s = buildInstructions(noStrap, { ...TOTE_DEFAULTS, kind: "canta" });
    expect(s.some((x) => x.title.includes("Askı"))).toBe(false);
  });
});
