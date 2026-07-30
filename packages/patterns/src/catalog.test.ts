import { describe, it, expect } from "vitest";
import {
  CATEGORIES,
  FAMILIES,
  categoryById,
  familyById,
  familiesByCategory,
  availableFamilies,
  categoryHasAvailable,
  STATUS_LABEL,
} from "./catalog.js";
import type { CardHolderParams } from "./cardholder.js";
import { DEFAULT_PARAMS, generateCardHolder } from "./cardholder.js";
import { buildInstructions, GLUE_CURE_MINUTES } from "./instructions.js";

describe("katalog", () => {
  it("kategori id'leri benzersiz ve sıralı", () => {
    const ids = CATEGORIES.map((c) => c.id);
    expect(new Set(ids).size).toBe(ids.length);
    const orders = CATEGORIES.map((c) => c.order);
    expect([...orders].sort((a, b) => a - b)).toEqual(orders);
  });

  it("aile id'leri benzersiz", () => {
    const ids = FAMILIES.map((f) => f.id);
    expect(new Set(ids).size).toBe(ids.length);
  });

  it("her aile tanımlı bir kategoriye ait", () => {
    for (const f of FAMILIES) {
      expect(categoryById(f.category)).toBeDefined();
    }
  });

  it("her kategoride en az bir aile var", () => {
    for (const c of CATEGORIES) {
      expect(familiesByCategory(c.id).length).toBeGreaterThan(0);
    }
  });

  it("yalnızca gerçekten üretilebilen aile hazır işaretli", () => {
    // DÜRÜSTLÜK TESTİ: bu liste büyürse jeneratörü de eklenmiş olmalı.
    // Var olmayan bir aileyi hazır göstermek kullanıcının zamanını çalar.
    expect(availableFamilies().map((f) => f.id).sort()).toEqual([
      "bifold",
      "card-holder-fold",
    ]);
  });

  it("kartlık ve cüzdanda üretilebilir aile var, çantada yok", () => {
    expect(categoryHasAvailable("kartlik")).toBe(true);
    expect(categoryHasAvailable("cuzdan")).toBe(true);
    expect(categoryHasAvailable("canta")).toBe(false);
  });

  it("bilinmeyen id undefined döner", () => {
    expect(familyById("yok")).toBeUndefined();
  });

  it("her durum için etiket var", () => {
    for (const f of FAMILIES) {
      expect(STATUS_LABEL[f.status]).toBeTruthy();
    }
  });

  it("kalınlık aralıkları tutarlı", () => {
    for (const f of FAMILIES) {
      if (f.typicalThickness !== undefined) {
        expect(f.typicalThickness.min).toBeLessThan(f.typicalThickness.max);
      }
    }
  });
});

describe("yapım adımları", () => {
  const pattern = generateCardHolder(DEFAULT_PARAMS);
  const steps = buildInstructions(pattern, DEFAULT_PARAMS);

  it("numaralar 1'den ardışık", () => {
    expect(steps.map((s) => s.n)).toEqual(steps.map((_, i) => i + 1));
  });

  it("ölçek doğrulamayla başlıyor, kontrolle bitiyor", () => {
    // "Ölçeği" — ünsüz yumuşaması yüzünden "Ölçek" araması tutmaz.
    expect(steps[0]?.title).toContain("Ölçe");
    expect(steps.at(-1)?.title).toContain("Kontrol");
  });

  it("adımlar KALIPTAN türetiliyor, sabit metin değil", () => {
    // Parametre değişince metin de değişmeli.
    // Nesne literalini doğrudan geçmek fazla-özellik denetimine takılır;
    // InstructionContext bilerek dar tutuldu.
    const p7: CardHolderParams = { ...DEFAULT_PARAMS, cardCount: 7 };
    const other = generateCardHolder(p7);
    const otherSteps = buildInstructions(other, p7);
    const glue = steps.find((s) => s.title === "Yapıştır");
    const otherGlue = otherSteps.find((s) => s.title === "Yapıştır");
    expect(glue?.body).not.toBe(otherGlue?.body);
  });

  it("delik sayısı ve adım metne giriyor", () => {
    const marking = steps.find((s) => s.title.includes("Delik"));
    expect(marking?.body).toContain(String(pattern.summary.totalHoles));
    expect(marking?.body).toContain(String(pattern.summary.pitch));
  });

  it("yuva kodları yapıştırma sırasında geçiyor", () => {
    const glue = steps.find((s) => s.title === "Yapıştır");
    for (const a of pattern.assembly) {
      expect(glue?.body).toContain(a.code);
    }
  });

  it("kritik uyarılar var: tutkal taşması ve kat bölgesi", () => {
    // Referans kalıptaki en değerli bilgi buydu — ürünü çöpe attıran hata.
    const glue = steps.find((s) => s.title === "Yapıştır");
    expect(glue?.warning).toBeDefined();
    expect(glue?.warning).toContain("dikiş hattının");
    expect(glue?.warning).toContain("kat");
  });

  it("kenar bitirmenin dikişten önce olduğu uyarısı var", () => {
    const edge = steps.find((s) => s.title.includes("Kenarları bitir"));
    expect(edge?.warning).toContain("ÖNCE");
  });

  it("damar yönü uyarısı var", () => {
    const prep = steps.find((s) => s.title.includes("Deriyi hazırla"));
    expect(prep?.warning).toContain("damar");
  });

  it("kuruma süresi saat olarak yazılıyor", () => {
    const cure = steps.find((s) => s.title.includes("Kelepçele"));
    expect(cure?.body).toContain(String(GLUE_CURE_MINUTES / 60));
  });

  it("kart sayısı arttıkça yapıştırma sırası uzuyor", () => {
    const p2: CardHolderParams = { ...DEFAULT_PARAMS, cardCount: 2 };
    const p8: CardHolderParams = { ...DEFAULT_PARAMS, cardCount: 8 };
    const few = buildInstructions(generateCardHolder(p2), p2);
    const many = buildInstructions(generateCardHolder(p8), p8);
    const seq = (x: typeof few) =>
      (x.find((s) => s.title === "Yapıştır")?.body ?? "").split("→").length;
    expect(seq(many)).toBeGreaterThan(seq(few));
  });
});
