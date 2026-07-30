#!/usr/bin/env bash
#
# 09_katalog_ve_adimlar.sh
#
# 1) Kalip katalogu: kategoriler (kartlik/cuzdan/canta/aksesuar) ve
#    urun aileleri, durum isaretleriyle
# 2) Yapim adimlari: kaliptan TURETILEN talimatlar, kritik uyarilarla
#    PDF'te ayri sayfa + arayuzde liste
#
# Repo kokunde calistir. Idempotent.

set -euo pipefail

if [ ! -f "pnpm-workspace.yaml" ] || [ ! -d "packages/print" ]; then
  echo "HATA: Repo kokunde calistirilmali ve 08 uygulanmis olmali." >&2
  exit 1
fi

echo "==> packages/patterns/src/catalog.ts"
cat > packages/patterns/src/catalog.ts << 'ODK_EOF_0'
import type { Mm } from "@odk/geometry";

/**
 * KALIP KATALOĞU
 *
 * Kategoriler ve ürün aileleri. Motorun ürettiği her kalıp bir aileye,
 * her aile bir kategoriye ait.
 *
 * DÜRÜSTLÜK KURALI: bir aile ancak gerçekten üretilebiliyorsa "hazır"
 * işaretlenir. Planlanan aileler listede görünür ama arayüz onları
 * kapalı gösterir. Var olmayan bir şeyi çalışıyormuş gibi listelemek,
 * kullanıcının zamanını çalar.
 */

export type CategoryId = "kartlik" | "cuzdan" | "canta" | "aksesuar";

export interface Category {
  readonly id: CategoryId;
  readonly name: string;
  readonly description: string;
  readonly order: number;
}

export const CATEGORIES: readonly Category[] = [
  {
    id: "kartlik",
    name: "Kartlık",
    description: "Sadece kart taşıyan ince modeller. En az katman, en az kalınlık.",
    order: 1,
  },
  {
    id: "cuzdan",
    name: "Cüzdan",
    description: "Kart, banknot ve bozuk para bölmelerinin birleştiği modeller.",
    order: 2,
  },
  {
    id: "canta",
    name: "Çanta",
    description: "Körüklü, askılı, hacimli modeller. Kalın deri ve yapısal dikiş.",
    order: 3,
  },
  {
    id: "aksesuar",
    name: "Aksesuar",
    description: "Kemer, anahtarlık, bileklik, kılıf gibi küçük ürünler.",
    order: 4,
  },
];

export type FamilyStatus = "hazir" | "gelistiriliyor" | "planlandi";

export interface PatternFamily {
  readonly id: string;
  readonly category: CategoryId;
  readonly name: string;
  readonly summary: string;
  readonly status: FamilyStatus;
  /** Bu ailenin kullandığı modüller. */
  readonly modules: readonly string[];
  /** Tipik kapalı kalınlık aralığı — kullanıcı beklentisini kurar. */
  readonly typicalThickness?: { readonly min: Mm; readonly max: Mm };
}

export const FAMILIES: readonly PatternFamily[] = [
  {
    id: "card-holder-fold",
    category: "kartlik",
    name: "Katlanır kartlık",
    summary:
      "Dış kabuk ortadan katlanır, kart yuvaları ön panele kademeli oturur.",
    status: "hazir",
    modules: ["CardSlot"],
    typicalThickness: { min: 4, max: 9 },
  },
  {
    id: "card-sleeve",
    category: "kartlik",
    name: "Düz kart kılıfı",
    summary: "Katsız, iki panel arasında tek bölme. En ince model.",
    status: "planlandi",
    modules: ["CardSlot"],
    typicalThickness: { min: 2, max: 4 },
  },
  {
    id: "bifold",
    category: "cuzdan",
    name: "Bifold cüzdan",
    summary: "Banknot bölmesi üzerinde iki yanda kart yuvaları.",
    status: "planlandi",
    modules: ["CardSlot", "BillPocket"],
    typicalThickness: { min: 6, max: 12 },
  },
  {
    id: "long-wallet",
    category: "cuzdan",
    name: "Uzun cüzdan",
    summary: "Banknot katlanmadan girer; fermuarlı bozuk para gözü eklenebilir.",
    status: "planlandi",
    modules: ["CardSlot", "BillPocket", "CoinPocket"],
    typicalThickness: { min: 8, max: 16 },
  },
  {
    id: "tote",
    category: "canta",
    name: "Körüklü çanta",
    summary: "Yan körük ve taban, askı bağlantıları.",
    status: "planlandi",
    modules: ["Gusset", "Divider"],
  },
  {
    id: "belt",
    category: "aksesuar",
    name: "Kemer",
    summary: "Tek parça şerit, toka bağlantısı ve delik dizisi.",
    status: "planlandi",
    modules: [],
  },
  {
    id: "key-case",
    category: "aksesuar",
    name: "Anahtarlık kılıfı",
    summary: "Katlanır kılıf, anahtar plakası bağlantısı.",
    status: "planlandi",
    modules: [],
  },
];

export function categoryById(id: CategoryId): Category | undefined {
  return CATEGORIES.find((c) => c.id === id);
}

export function familyById(id: string): PatternFamily | undefined {
  return FAMILIES.find((f) => f.id === id);
}

export function familiesByCategory(id: CategoryId): PatternFamily[] {
  return FAMILIES.filter((f) => f.category === id);
}

/** Şu anda gerçekten kalıp üretilebilen aileler. */
export function availableFamilies(): PatternFamily[] {
  return FAMILIES.filter((f) => f.status === "hazir");
}

/** Kategoride üretilebilir aile var mı? Arayüz kategoriyi kapatmak için kullanır. */
export function categoryHasAvailable(id: CategoryId): boolean {
  return FAMILIES.some((f) => f.category === id && f.status === "hazir");
}

export const STATUS_LABEL: Record<FamilyStatus, string> = {
  hazir: "hazır",
  gelistiriliyor: "geliştiriliyor",
  planlandi: "planlandı",
};
ODK_EOF_0

echo "==> packages/patterns/src/instructions.ts"
cat > packages/patterns/src/instructions.ts << 'ODK_EOF_1'
import type { Mm } from "@odk/geometry";
import type { CardHolderParams, PatternResult } from "./cardholder.js";
import { PROVISIONAL_SKIVE_FACTOR } from "./material.js";

/**
 * YAPIM ADIMLARI
 *
 * Adımlar SABİT METİN DEĞİL, kalıptan türetiliyor. Parça sayısı, delik
 * adedi, tutkal sınırı, kuruma süresi — hepsi hesaptan geliyor. Kullanıcı
 * kart sayısını değiştirdiğinde talimat da değişiyor.
 *
 * Neden önemli: sabit metin, parametrik bir kalıpla er geç çelişir.
 * "3 parçayı kes" yazan bir talimatın yanında 5 parça basılıysa
 * kullanıcı hangisine güveneceğini bilemez.
 */

export interface InstructionStep {
  readonly n: number;
  readonly title: string;
  readonly body: string;
  /**
   * Bu adımda yapılan hata ürünü çöpe atıyorsa uyarı.
   * Referans kalıplarda en değerli bilgi buydu: "çoğu kişi bu hatayı
   * yapıyor ve baştan başlamak zorunda kalıyor."
   */
  readonly warning?: string;
}

/** Tutkal kuruma süresi (dakika). Kontak yapıştırıcı için tipik. */
export const GLUE_CURE_MINUTES = 120;

export function buildInstructions(
  pattern: PatternResult,
  params: CardHolderParams,
): InstructionStep[] {
  const s = pattern.summary;
  const steps: InstructionStep[] = [];
  let n = 0;
  const add = (
    title: string,
    body: string,
    warning?: string,
  ): void => {
    n += 1;
    steps.push(warning === undefined ? { n, title, body } : { n, title, body, warning });
  };

  const totalPaperPieces = pattern.pieces.reduce((a, p) => a + p.quantity, 0);
  const pieceList = pattern.pieces
    .map((p) => `${p.code} ×${p.quantity}`)
    .join(", ");

  // Deri türleri: aynı kalınlıktakiler tek satırda.
  const byThickness = new Map<Mm, string[]>();
  for (const p of pattern.pieces) {
    const list = byThickness.get(p.leatherThickness) ?? [];
    list.push(`${p.code} ×${p.quantity}`);
    byThickness.set(p.leatherThickness, list);
  }
  const leatherLines = [...byThickness.entries()]
    .sort((a, b) => b[0] - a[0])
    .map(([t, codes]) => `${t.toFixed(1)}mm: ${codes.join(", ")}`)
    .join(" · ");

  add(
    "Ölçeği doğrula",
    `Kapak sayfasındaki 50mm kareyi cetvelle ölç. 50mm değilse ölçtüğün ` +
      `değeri uygulamaya gir, PDF'i yeniden indir ve aynı yazıcı ayarıyla bas.`,
    `Bu adımı atlarsan sonraki her ölçü yanlış olur. Kalıbın hassasiyeti ` +
      `baskı ölçeğinden daha iyi olamaz.`,
  );

  add(
    "Kağıt parçaları kes",
    `Toplam ${totalPaperPieces} parça: ${pieceList}. Kesim çizgisini ` +
      `kağıtta bırak, dışından kes. Kalınca bir kartona yapıştırmak ` +
      `deriye çizerken şablonun kaymasını önler.`,
  );

  add(
    "Deriyi hazırla",
    `Kalınlıklar — ${leatherLines}. Şablonları deri üzerine damar yönü ` +
      `aynı olacak şekilde yerleştir; her parçada damar oku basılı.`,
    `Parçalar farklı damar yönlerinde kesilirse ürün kullandıkça ` +
      `çarpılır ve kenarlar hizasını kaybeder.`,
  );

  add(
    "Delikleri işaretle",
    `Şablonu deriye bantla ve işaretli noktalardan del. ` +
      `${s.pitch}mm pricking iron, toplam ${s.totalHoles} delik. ` +
      `Delikleri deriyi kesmeden önce açmak hizayı korur.`,
  );

  add(
    "Deriyi kes",
    `Kesim hattını takip et. Kalem payı ${params.penAllowance}mm olarak ` +
      `hesaba katıldı; şablonun dış kenarından çizip çizginin dışından ` +
      `kesersen nominal ölçüye ulaşırsın.`,
  );

  const overlapCount = pattern.assembly.length;
  add(
    "Kenarları tıraşla",
    `${overlapCount} yuva üst üste bineceği için örtüşen kenarları ` +
      `tıraşla (skive). Tıraşlama kalınlığı yaklaşık yarıya indirir; ` +
      `kenar kalınlığı ${s.edgeThickness.toFixed(1)}mm'den ` +
      `${(s.edgeThickness * PROVISIONAL_SKIVE_FACTOR).toFixed(1)}mm'ye ` +
      `civarına düşer.`,
  );

  // Tutkal sınırı: dikiş hattının dışındaki bant.
  const glueBandWidth = params.stitchMargin;
  add(
    "Yapıştır",
    `En alttan başla. Yuvaları ${params.reveal}mm kademeyle diz: ` +
      `${pattern.assembly.map((a) => a.code).join(" → ")}. ` +
      `Tutkalı yalnızca kenarlardaki ${glueBandWidth.toFixed(1)}mm'lik ` +
      `banda sür.`,
    `Tutkal dikiş hattının İÇİNE taşarsa kart yuvası yapışır ve ürün ` +
      `kullanılamaz hale gelir. Ayrıca kat bölgesine ` +
      `(${s.foldAllowance.toFixed(1)}mm'lik şerit) tutkal sürme — ` +
      `sürülürse cüzdan katlanmaz.`,
  );

  add(
    "Kelepçele ve beklet",
    `Parçaları kelepçe ya da mandalla sabitle ve tutkalın kuruması için ` +
      `yaklaşık ${GLUE_CURE_MINUTES / 60} saat bekle.`,
  );

  add(
    "Kenarları bitir",
    `Kenarları zımparala, kenar boyası ya da cila uygula. Kurumasını ` +
      `bekle ve gerekirse ikinci kat çek.`,
    `Kenar bitirme dikişten ÖNCE yapılır. Dikişten sonra iplik boyanır ` +
      `ve zımpara ipliği aşındırır.`,
  );

  const outer = pattern.pieces.find((p) => p.stitchPlan !== undefined);
  add(
    "Dik",
    `Eyer dikişi (saddle stitch) ile ${s.totalHoles} delikten geç. ` +
      `İplik boyu delik sayısının yaklaşık ` +
      `${Math.ceil(((outer?.stitchPlan?.totalHoles ?? s.totalHoles) * s.pitch * 3.5) / 1000)}` +
      ` metre kadarı olmalı (çevrenin ~3.5 katı).`,
  );

  add(
    "Kontrol et",
    `Kapalı kalınlık ${s.closedThickness.toFixed(1)}mm, kartlar takılıyken ` +
      `${s.loadedThickness.toFixed(1)}mm olmalı. Belirgin sapma varsa deri ` +
      `kalınlığı ya da tıraşlama farklı çıkmıştır — ölçüp uygulamaya geri bildir.`,
  );

  return steps;
}
ODK_EOF_1

echo "==> packages/patterns/src/catalog.test.ts"
cat > packages/patterns/src/catalog.test.ts << 'ODK_EOF_2'
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
    expect(availableFamilies().map((f) => f.id)).toEqual(["card-holder-fold"]);
  });

  it("kartlık kategorisinde üretilebilir aile var, çantada yok", () => {
    expect(categoryHasAvailable("kartlik")).toBe(true);
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
    const other = generateCardHolder({ ...DEFAULT_PARAMS, cardCount: 7 });
    const otherSteps = buildInstructions(other, {
      ...DEFAULT_PARAMS,
      cardCount: 7,
    });
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
    const few = buildInstructions(
      generateCardHolder({ ...DEFAULT_PARAMS, cardCount: 2 }),
      { ...DEFAULT_PARAMS, cardCount: 2 },
    );
    const many = buildInstructions(
      generateCardHolder({ ...DEFAULT_PARAMS, cardCount: 8 }),
      { ...DEFAULT_PARAMS, cardCount: 8 },
    );
    const seq = (x: typeof few) =>
      (x.find((s) => s.title === "Yapıştır")?.body ?? "").split("→").length;
    expect(seq(many)).toBeGreaterThan(seq(few));
  });
});
ODK_EOF_2

echo "==> packages/patterns/src/index.ts"
cat > packages/patterns/src/index.ts << 'ODK_EOF_3'
/**
 * @odk/patterns — malzeme modeli, kesit çözücü, modül tanımları.
 *
 * Bu paket de saf kalır: platform API'si import etmez.
 */

export * from "./material.js";
export * from "./crosssection.js";
export * from "./cardslot.js";
export * from "./cardholder.js";
export * from "./catalog.js";
export * from "./instructions.js";
ODK_EOF_3

echo "==> packages/print/src/pdf.ts"
cat > packages/print/src/pdf.ts << 'ODK_EOF_4'
import type { PDFDocument, PDFFont, PDFPage } from "pdf-lib";
import {
  PDFDocument as PDFDoc,
  rgb,
  pushGraphicsState,
  popGraphicsState,
  moveTo,
  lineTo,
  closePath,
  clip,
  endPath,
} from "pdf-lib";
import fontkit from "@pdf-lib/fontkit";
import type { Mm, Polyline, Vec } from "@odk/geometry";
import { mmToPt, stitchSummary } from "@odk/geometry";
import type {
  PatternResult,
  PatternPiece,
  CardHolderParams,
  InstructionStep,
} from "@odk/patterns";
import { buildInstructions } from "@odk/patterns";
import type { PaperSpec, TileGrid } from "./paper.js";
import {
  A4_PORTRAIT,
  printableArea,
  planTiles,
  tileOrigin,
  tileCode,
  CALIBRATION_SQUARE,
} from "./paper.js";
import type { LineStyle, PlacedPiece, SheetLayout } from "./layout.js";
import { packPieces, STYLES } from "./layout.js";

/**
 * PDF ÜRETİCİ
 *
 * Tek kural: çıktı 1:1. Koordinatlar milimetre olarak hesaplanır ve
 * yalnızca pdf-lib'e verilirken point'e çevrilir (mmToPt). Başka hiçbir
 * yerde birim dönüşümü yok — ölçek hatalarının en yaygın kaynağı budur.
 */

export interface PdfFonts {
  /** Gövde metni için TTF/OTF baytları. Türkçe karakterler şart. */
  readonly regular: Uint8Array;
  /** Ölçüler için monospace TTF/OTF baytları. */
  readonly mono: Uint8Array;
}

export interface PdfOptions {
  readonly paper?: PaperSpec;
  /**
   * Kalibrasyon düzeltmesi. 1 = düzeltme yok.
   * scaleFromMeasurement() ile hesaplanır.
   */
  readonly scaleFactor?: number;
  /**
   * Dikiş deliklerini tek tek bas.
   *
   * Varsayılan AÇIK.
   *
   * İlk sürümde kapalıydı; gerekçem "kullanıcı ironu kendisi yürür,
   * basılmış nokta yanıltır" idi. Ticari kalıpları inceleyince bu
   * varsayımın yanlış olduğu görüldü: yaygın iş akışı kağıt şablonu
   * deriye bantlayıp İŞARETLİ NOKTALARDAN delmek, sonra hattı kesmek.
   * Yani noktalar şablonun asıl işlevlerinden biri.
   *
   * Kapalıyken yalnızca köşe çapaları basılır; ironu kendisi yürütenler
   * için hâlâ geçerli bir seçenek.
   */
  readonly printAllHoles?: boolean;
  readonly title?: string;
  readonly version?: string;
  /**
   * Verilirse yapım adımları sayfası eklenir.
   *
   * Adımlar kalıptan türetildiği için parametrelere ihtiyaç var;
   * PatternResult tek başına yetmiyor.
   */
  readonly params?: CardHolderParams;
}

const BLACK = rgb(0, 0, 0);

function gray(g: number) {
  return rgb(g, g, g);
}

interface Ctx {
  readonly doc: PDFDocument;
  readonly body: PDFFont;
  readonly mono: PDFFont;
  readonly paper: PaperSpec;
  readonly scale: number;
}

export async function buildPatternPdf(
  pattern: PatternResult,
  fonts: PdfFonts,
  options: PdfOptions = {},
): Promise<Uint8Array> {
  const paper = options.paper ?? A4_PORTRAIT;
  const scale = options.scaleFactor ?? 1;

  const doc = await PDFDoc.create();
  doc.registerFontkit(fontkit);
  const body = await doc.embedFont(fonts.regular, { subset: true });
  const mono = await doc.embedFont(fonts.mono, { subset: true });

  doc.setTitle(options.title ?? "Deri kalıbı");
  doc.setCreator("oto_deri_kalip");

  const ctx: Ctx = { doc, body, mono, paper, scale };

  const layout = packPieces(pattern.pieces, paper);
  const grid = planTiles(layout.width, layout.height, paper);

  drawCoverPage(ctx, pattern, layout, grid, options);
  drawAssemblyPage(ctx, pattern);
  if (options.params !== undefined) {
    drawInstructionPages(ctx, buildInstructions(pattern, options.params));
  }

  for (let row = 0; row < grid.rows; row++) {
    for (let col = 0; col < grid.cols; col++) {
      drawTilePage(ctx, pattern, layout, grid, col, row, options);
    }
  }

  return doc.save();
}

// --- Yardımcılar -----------------------------------------------------------

function addPage(ctx: Ctx): PDFPage {
  return ctx.doc.addPage([mmToPt(ctx.paper.width), mmToPt(ctx.paper.height)]);
}

function line(
  page: PDFPage,
  a: Vec,
  b: Vec,
  style: LineStyle,
  scale: number,
): void {
  // exactOptionalPropertyTypes altında dashArray'e undefined atanamaz;
  // sürekli çizgide anahtarı hiç eklemiyoruz.
  const dash =
    style.dash.length > 0
      ? { dashArray: style.dash.map((d) => mmToPt(d * scale)) }
      : {};
  page.drawLine({
    start: { x: mmToPt(a.x), y: mmToPt(a.y) },
    end: { x: mmToPt(b.x), y: mmToPt(b.y) },
    thickness: mmToPt(style.width),
    color: gray(style.gray),
    ...dash,
  });
}

function polyline(
  page: PDFPage,
  poly: Polyline,
  closedPath: boolean,
  style: LineStyle,
  scale: number,
): void {
  for (let i = 0; i < poly.length - 1; i++) {
    line(page, poly[i] as Vec, poly[i + 1] as Vec, style, scale);
  }
  if (closedPath && poly.length > 2) {
    line(page, poly.at(-1) as Vec, poly[0] as Vec, style, scale);
  }
}

function text(
  page: PDFPage,
  s: string,
  x: Mm,
  y: Mm,
  size: number,
  font: PDFFont,
  g = 0,
): void {
  page.drawText(s, {
    x: mmToPt(x),
    y: mmToPt(y),
    size,
    font,
    color: gray(g),
  });
}

// --- Kapak sayfası ---------------------------------------------------------

function drawCoverPage(
  ctx: Ctx,
  pattern: PatternResult,
  layout: SheetLayout,
  grid: TileGrid,
  options: PdfOptions,
): void {
  const page = addPage(ctx);
  const area = printableArea(ctx.paper);
  const left = area.originX;
  let y = ctx.paper.height - ctx.paper.printerMargin - 8;

  text(page, options.title ?? "Kartlık — kalıp", left, y, 18, ctx.body);
  y -= 7;
  text(
    page,
    `${options.version ?? "v1"} · ${grid.cols * grid.rows} desen sayfası · ölçek 1:1`,
    left,
    y,
    9,
    ctx.mono,
    0.4,
  );

  // ── Kalibrasyon karesi ───────────────────────────────────────────────
  y -= 14;
  text(page, "1 — Önce ölçeği doğrula", left, y, 12, ctx.body);
  y -= 6;
  const instructions = [
    "Yazdırırken ölçek %100 / Actual size olmalı.",
    "\"Sayfaya sığdır\" / \"Fit to page\" KAPALI olmalı.",
    "Aşağıdaki karenin kenarını cetvelle ölç.",
    "50mm değilse ölçtüğün değeri uygulamaya gir ve PDF'i yeniden indir.",
  ];
  for (const linetext of instructions) {
    text(page, linetext, left, y, 9, ctx.body, 0.25);
    y -= 4.6;
  }

  y -= CALIBRATION_SQUARE + 3;
  const sq = CALIBRATION_SQUARE * ctx.scale;
  page.drawRectangle({
    x: mmToPt(left),
    y: mmToPt(y),
    width: mmToPt(sq),
    height: mmToPt(sq),
    borderWidth: mmToPt(STYLES.cut.width),
    borderColor: BLACK,
  });
  // Kenar ortalarına 10mm'lik tik işaretleri: cetveli hizalamayı kolaylaştırır.
  for (let t = 10; t < CALIBRATION_SQUARE; t += 10) {
    const tx = left + t * ctx.scale;
    line(page, { x: tx, y }, { x: tx, y: y + 2 * ctx.scale }, STYLES.guide, ctx.scale);
  }
  text(page, `${CALIBRATION_SQUARE} mm`, left + sq + 4, y + sq / 2, 10, ctx.mono);

  // ── Kesim kuralı ─────────────────────────────────────────────────────
  y -= 10;
  text(page, "2 — Çizginin dışından kes", left, y, 12, ctx.body);
  y -= 5.5;
  text(
    page,
    "Kesim çizgisi 0.2mm. Çizgiyi kağıtta bırak, dışından kes.",
    left,
    y,
    9,
    ctx.body,
    0.25,
  );

  // ── Parça listesi ────────────────────────────────────────────────────
  y -= 12;
  text(page, "3 — Parçalar", left, y, 12, ctx.body);
  y -= 6;
  text(page, "kod", left, y, 8, ctx.mono, 0.5);
  text(page, "parça", left + 12, y, 8, ctx.mono, 0.5);
  text(page, "adet", left + 55, y, 8, ctx.mono, 0.5);
  text(page, "ölçü (mm)", left + 70, y, 8, ctx.mono, 0.5);
  text(page, "deri", left + 110, y, 8, ctx.mono, 0.5);
  y -= 1.5;
  line(page, { x: left, y }, { x: left + area.width, y }, STYLES.guide, 1);
  y -= 4.5;

  for (const p of pattern.pieces) {
    text(page, p.code, left, y, 9, ctx.mono);
    text(page, p.name, left + 12, y, 9, ctx.body);
    text(page, `${p.quantity}`, left + 55, y, 9, ctx.mono);
    text(
      page,
      `${p.width.toFixed(1)} × ${p.height.toFixed(1)}`,
      left + 70,
      y,
      9,
      ctx.mono,
    );
    text(page, `${p.leatherThickness.toFixed(1)}mm`, left + 110, y, 9, ctx.mono);
    y -= 4.8;
  }

  // ── Dikiş planı ──────────────────────────────────────────────────────
  const outer = pattern.pieces.find((p) => p.stitchPlan !== undefined);
  if (outer?.stitchPlan !== undefined) {
    y -= 8;
    text(page, "4 — Dikiş", left, y, 12, ctx.body);
    y -= 5.5;
    text(
      page,
      `${outer.stitchPlan.pitch}mm pricking iron · toplam ${outer.stitchPlan.totalHoles} delik`,
      left,
      y,
      9,
      ctx.mono,
      0.25,
    );
    y -= 5;
    for (const s of stitchSummary(outer.stitchPlan)) {
      text(page, s, left, y, 8.5, ctx.mono, 0.35);
      y -= 4.2;
    }
  }

  // ── Ölçüler ──────────────────────────────────────────────────────────
  const s = pattern.summary;
  y -= 8;
  text(page, "5 — Ölçüler", left, y, 12, ctx.body);
  y -= 5.5;
  const rows: [string, string][] = [
    ["bölme genişliği", `${s.compartmentWidth.toFixed(1)} mm`],
    ["kat payı", `${s.foldAllowance.toFixed(2)} mm`],
    ["kapalı kalınlık", `${s.closedThickness.toFixed(2)} mm`],
    ["kart yüklü", `${s.loadedThickness.toFixed(2)} mm`],
    ["kenar kalınlığı", `${s.edgeThickness.toFixed(2)} mm`],
  ];
  for (const [k, v] of rows) {
    text(page, k, left, y, 9, ctx.body, 0.3);
    text(page, v, left + 55, y, 9, ctx.mono);
    y -= 4.4;
  }

  // ── Uyarılar ─────────────────────────────────────────────────────────
  if (pattern.diagnostics.length > 0) {
    y -= 8;
    text(page, "Uyarılar", left, y, 12, ctx.body);
    y -= 5.5;
    for (const d of pattern.diagnostics) {
      const prefix = d.severity === "error" ? "HATA" : "UYARI";
      const wrapped = wrap(`${prefix} — ${d.message}`, 88);
      for (const w of wrapped) {
        text(page, w, left, y, 8.5, ctx.body, 0.2);
        y -= 4;
      }
      y -= 1;
    }
  }

  drawFooter(ctx, page, "kapak", 0);
}

/** Basit sözcük sarma; PDF'te otomatik sarma yok. */
function wrap(s: string, maxChars: number): string[] {
  const words = s.split(" ");
  const lines: string[] = [];
  let cur = "";
  for (const w of words) {
    if (cur.length + w.length + 1 > maxChars) {
      if (cur.length > 0) lines.push(cur);
      cur = w;
    } else {
      cur = cur.length === 0 ? w : `${cur} ${w}`;
    }
  }
  if (cur.length > 0) lines.push(cur);
  return lines;
}

// --- Ölçü çizgileri --------------------------------------------------------

/**
 * Uzatma çizgileri, oklar ve ortalanmış metinle ölçü çizgisi.
 *
 * Referans olarak incelediğimiz ticari kalıplarda ölçüler çizimin
 * ÜSTÜNDE gösteriliyor, sadece etiket metninde değil. Fark şu: kullanıcı
 * kağıdı cetvelle kontrol ederken hangi iki nokta arasını ölçeceğini
 * çizimden görüyor. "99.4 × 194.4mm" yazısı bunu söylemiyor.
 */
function dimension(
  ctx: Ctx,
  page: PDFPage,
  a: Vec,
  b: Vec,
  offset: Mm,
  label: string,
  vertical: boolean,
): void {
  const style = STYLES.guide;
  const arm = 2;

  const oa = vertical ? { x: a.x - offset, y: a.y } : { x: a.x, y: a.y + offset };
  const ob = vertical ? { x: b.x - offset, y: b.y } : { x: b.x, y: b.y + offset };

  // Uzatma çizgileri: ölçülen kenardan ölçü çizgisine.
  line(page, a, vertical ? { x: oa.x - arm, y: a.y } : { x: a.x, y: oa.y + arm }, style, 1);
  line(page, b, vertical ? { x: ob.x - arm, y: b.y } : { x: b.x, y: ob.y + arm }, style, 1);

  // Ölçü çizgisi.
  line(page, oa, ob, style, 1);

  // Uç işaretleri (45° eğik çizgi — ok başından daha net basılıyor).
  for (const p of [oa, ob]) {
    line(
      page,
      { x: p.x - 1.2, y: p.y - 1.2 },
      { x: p.x + 1.2, y: p.y + 1.2 },
      STYLES.cut,
      1,
    );
  }

  const mid = { x: (oa.x + ob.x) / 2, y: (oa.y + ob.y) / 2 };
  const w = ctx.mono.widthOfTextAtSize(label, 8) / mmToPt(1);
  if (vertical) {
    text(page, label, mid.x - w - 1.5, mid.y - 1, 8, ctx.mono, 0.15);
  } else {
    text(page, label, mid.x - w / 2, mid.y + 1.5, 8, ctx.mono, 0.15);
  }
}

// --- Montaj sayfası --------------------------------------------------------

/**
 * Parçaların bitmiş üründeki yerleşimi.
 *
 * BU SAYFA EN ÇOK EKSİK OLANDI. Önceki sürümde kalıp, birbirinden
 * bağımsız parçalar listesiydi; hangi parçanın nereye geldiği yalnızca
 * kullanıcının kafasındaydı. Referans kalıplarda "Completed Wallet"
 * sayfası tam olarak bunu çözüyor.
 */
function drawAssemblyPage(ctx: Ctx, pattern: PatternResult): void {
  const page = addPage(ctx);
  const area = printableArea(ctx.paper);
  const left = area.originX;
  let y = ctx.paper.height - ctx.paper.printerMargin - 8;

  text(page, "Montaj — açık hâl", left, y, 15, ctx.body);
  y -= 6;
  text(
    page,
    "Yuvalar ön panele oturur; her yuva bir kademe yukarıda.",
    left,
    y,
    9,
    ctx.body,
    0.3,
  );

  const outer = pattern.pieces.find((p) => p.id === "outer");
  if (outer === undefined) {
    drawFooter(ctx, page, "montaj", 0);
    return;
  }

  // Çizimi sayfaya sığdır: ölçekle, çünkü bu sayfa 1:1 DEĞİL.
  const drawH = y - area.originY - 26;
  const fit = Math.min(1, (area.width - 40) / outer.width, drawH / outer.height);
  const ox = left + 24;
  const oy = area.originY + 20;

  const minX = Math.min(...outer.cutLine.map((p) => p.x));
  const minY = Math.min(...outer.cutLine.map((p) => p.y));
  const place = (p: Vec, dx = 0, dy = 0): Vec => ({
    x: ox + (p.x - minX + dx) * fit,
    y: oy + (p.y - minY + dy) * fit,
  });

  polyline(page, outer.cutLine.map((p) => place(p)), true, STYLES.cut, 1);
  for (const fold of outer.foldLines) {
    line(page, place(fold.from), place(fold.to), STYLES.fold, 1);
  }

  // Yuvalar, montajdaki konumlarında.
  for (const a of pattern.assembly) {
    const piece = pattern.pieces.find((p) => p.id === a.pieceId);
    if (piece === undefined) continue;
    const pminX = Math.min(...piece.cutLine.map((p) => p.x));
    const pminY = Math.min(...piece.cutLine.map((p) => p.y));
    const poly = piece.cutLine.map((p) =>
      place({ x: p.x - pminX + a.x, y: p.y - pminY + a.y }),
    );
    polyline(page, poly, true, STYLES.guide, 1);

    const anchor = place({ x: a.x + 4, y: a.y + 3 });
    text(page, a.code, anchor.x, anchor.y, 7.5, ctx.mono, 0.2);
  }

  text(
    page,
    outer.code,
    ox + 3 * fit,
    oy + (outer.height - 6) * fit,
    9,
    ctx.mono,
    0.2,
  );

  // Ölçüler.
  const bl = place({ x: 0, y: 0 });
  const br = place({ x: outer.width, y: 0 });
  const tl = place({ x: 0, y: outer.height });
  dimension(ctx, page, bl, br, 10, `${outer.width.toFixed(1)} mm`, false);
  dimension(ctx, page, bl, tl, 12, `${outer.height.toFixed(1)} mm`, true);

  text(
    page,
    `bu sayfa ölçekli (×${fit.toFixed(2)}) — kesim için desen sayfalarını kullan`,
    left,
    area.originY + 4,
    8,
    ctx.mono,
    0.45,
  );

  drawFooter(ctx, page, "montaj", 0);
}

// --- Yapım adımları --------------------------------------------------------

/**
 * Adımlar sayfası. Sığmayan adımlar bir sonraki sayfaya taşar.
 *
 * Sayfa taşması hesaplanarak yapılıyor, sabit "sayfa başına 6 adım"
 * gibi bir varsayımla değil: adım metinleri kalıptan türediği için
 * uzunlukları parametrelere göre değişiyor.
 */
function drawInstructionPages(ctx: Ctx, steps: readonly InstructionStep[]): void {
  const area = printableArea(ctx.paper);
  const left = area.originX;
  const bottomLimit = area.originY + 4;
  const wrapWidth = 84;

  let page = addPage(ctx);
  let pageIndex = 1;
  let y = ctx.paper.height - ctx.paper.printerMargin - 8;

  text(page, "Yapım adımları", left, y, 15, ctx.body);
  y -= 9;

  for (const step of steps) {
    const bodyLines = wrap(step.body, wrapWidth);
    const warnLines =
      step.warning === undefined ? [] : wrap(step.warning, wrapWidth - 4);
    const needed = 6 + bodyLines.length * 4.2 + (warnLines.length * 4 + 3) + 5;

    if (y - needed < bottomLimit) {
      drawFooter(ctx, page, `adımlar ${pageIndex}`, 0);
      page = addPage(ctx);
      pageIndex += 1;
      y = ctx.paper.height - ctx.paper.printerMargin - 8;
      text(page, `Yapım adımları (devam)`, left, y, 15, ctx.body);
      y -= 9;
    }

    // Numara solda, metin girintili — göz kolayca adım sınırlarını buluyor.
    text(page, `${step.n}`, left, y, 11, ctx.mono, 0.45);
    text(page, step.title, left + 8, y, 11.5, ctx.body);
    y -= 5.4;

    for (const bl of bodyLines) {
      text(page, bl, left + 8, y, 9, ctx.body, 0.25);
      y -= 4.2;
    }

    if (warnLines.length > 0) {
      y -= 1;
      const boxTop = y + 3.5;
      const boxHeight = warnLines.length * 4 + 2;
      // Sol kenarda kalın çubuk: uyarıyı gövdeden ayırıyor. Renk yerine
      // konum ve kalınlık kullanılıyor, siyah-beyaz baskıda da ayrışsın.
      page.drawRectangle({
        x: mmToPt(left + 8),
        y: mmToPt(boxTop - boxHeight),
        width: mmToPt(0.8),
        height: mmToPt(boxHeight),
        color: gray(0.15),
      });
      for (const wl of warnLines) {
        text(page, wl, left + 11, y, 8.5, ctx.body, 0.1);
        y -= 4;
      }
    }

    y -= 5;
  }

  drawFooter(ctx, page, `adımlar ${pageIndex}`, 0);
}

// --- Desen sayfaları -------------------------------------------------------

function drawTilePage(
  ctx: Ctx,
  pattern: PatternResult,
  layout: SheetLayout,
  grid: TileGrid,
  col: number,
  row: number,
  options: PdfOptions,
): void {
  const page = addPage(ctx);
  const area = printableArea(ctx.paper);
  const origin = tileOrigin(grid, col, row);

  // İçeriği basılabilir alana kırp: taşan kısım komşu sayfada.
  page.pushOperators(
    pushGraphicsState(),
    moveTo(mmToPt(area.originX), mmToPt(area.originY)),
    lineTo(mmToPt(area.originX + area.width), mmToPt(area.originY)),
    lineTo(mmToPt(area.originX + area.width), mmToPt(area.originY + area.height)),
    lineTo(mmToPt(area.originX), mmToPt(area.originY + area.height)),
    closePath(),
    clip(),
    endPath(),
  );

  // Tabaka koordinatı -> sayfa koordinatı.
  const tx = (p: Vec): Vec => ({
    x: area.originX + (p.x - origin.x) * ctx.scale,
    y: area.originY + (p.y - origin.y) * ctx.scale,
  });

  for (const placed of layout.placed) {
    drawPiece(ctx, page, placed, tx, options.printAllHoles ?? true);
  }

  page.pushOperators(popGraphicsState());

  drawTileMarks(ctx, page, grid, col, row);
  drawFooter(ctx, page, tileCode(col, row), grid.cols * grid.rows);
}

function drawPiece(
  ctx: Ctx,
  page: PDFPage,
  placed: PlacedPiece,
  tx: (p: Vec) => Vec,
  printAllHoles: boolean,
): void {
  const piece = placed.piece;

  // Parçanın kendi koordinatları sıfırlanıp tabakadaki yerine taşınıyor.
  const minX = Math.min(...piece.cutLine.map((p) => p.x));
  const minY = Math.min(...piece.cutLine.map((p) => p.y));
  const place = (p: Vec): Vec =>
    tx({ x: placed.x + (p.x - minX), y: placed.y + (p.y - minY) });

  polyline(page, piece.cutLine.map(place), true, STYLES.cut, ctx.scale);

  if (piece.stitchLine !== undefined) {
    polyline(page, piece.stitchLine.map(place), true, STYLES.stitch, ctx.scale);
  }

  for (const fold of piece.foldLines) {
    line(page, place(fold.from), place(fold.to), STYLES.fold, ctx.scale);
  }

  if (piece.stitchPlan !== undefined) {
    const holes = printAllHoles
      ? piece.stitchPlan.holes
      : piece.stitchPlan.holes.filter((h) => h.isAnchor);
    for (const hole of holes) {
      const p = place(hole.position);
      page.drawCircle({
        x: mmToPt(p.x),
        y: mmToPt(p.y),
        size: mmToPt(0.5 * ctx.scale),
        borderWidth: mmToPt(0.15),
        borderColor: gray(0.3),
      });
    }
  }

  // Etiket: parçanın sol-üst köşesinin biraz üstünde.
  const label = tx({
    x: placed.x,
    y: placed.y + placed.height + 3,
  });
  text(
    page,
    `${piece.code} · ${piece.name}  ×${piece.quantity}  ${piece.width.toFixed(1)}×${piece.height.toFixed(1)}mm  ${piece.leatherThickness.toFixed(1)}mm deri`,
    label.x,
    label.y,
    7.5,
    ctx.mono,
    0.3,
  );

  // Damar yönü: deri postun boyuna göre daha az esner; parçalar aynı
  // yönde kesilmezse ürün çarpılır.
  const grainStart = tx({ x: placed.x + 2, y: placed.y + 2 });
  const grainEnd = tx({ x: placed.x + 2, y: placed.y + 14 });
  line(page, grainStart, grainEnd, STYLES.guide, ctx.scale);
  text(page, "damar", grainStart.x + 1.5, grainStart.y + 4, 6, ctx.mono, 0.55);
}

/**
 * Hizalama işaretleri.
 *
 * Kullanıcı sayfaları kesip bindirerek yapıştırıyor. Kesme hattı ve
 * dört köşedeki haçlar, komşu sayfayla üst üste getirildiğinde
 * çakışacak şekilde konumlanıyor.
 */
function drawTileMarks(
  ctx: Ctx,
  page: PDFPage,
  grid: TileGrid,
  col: number,
  row: number,
): void {
  const area = printableArea(ctx.paper);
  const x0 = area.originX;
  const y0 = area.originY;
  const x1 = x0 + area.width;
  const y1 = y0 + area.height;

  // Kesme çerçevesi.
  polyline(
    page,
    [
      { x: x0, y: y0 },
      { x: x1, y: y0 },
      { x: x1, y: y1 },
      { x: x0, y: y1 },
    ],
    true,
    STYLES.trim,
    1,
  );

  // Bindirme sınırı: sağda ve altta (bir sonraki sayfanın başladığı yer).
  if (col < grid.cols - 1) {
    line(
      page,
      { x: x1 - grid.overlap, y: y0 },
      { x: x1 - grid.overlap, y: y1 },
      STYLES.guide,
      1,
    );
  }
  if (row < grid.rows - 1) {
    line(
      page,
      { x: x0, y: y0 + grid.overlap },
      { x: x1, y: y0 + grid.overlap },
      STYLES.guide,
      1,
    );
  }

  // Köşe haçları.
  const arm = 4;
  for (const [cx, cy] of [
    [x0, y0],
    [x1, y0],
    [x0, y1],
    [x1, y1],
  ] as const) {
    line(page, { x: cx - arm, y: cy }, { x: cx + arm, y: cy }, STYLES.guide, 1);
    line(page, { x: cx, y: cy - arm }, { x: cx, y: cy + arm }, STYLES.guide, 1);
  }
}

/** Her sayfanın altında: ölçek çubuğu, uyarı, sayfa kodu. */
function drawFooter(ctx: Ctx, page: PDFPage, code: string, totalTiles: number): void {
  const m = ctx.paper.printerMargin;
  const y = m + 4;

  // 50mm ölçek çubuğu, 10mm tikli. Her sayfada ölçek doğrulanabilsin diye.
  const barLength = 50 * ctx.scale;
  line(page, { x: m, y }, { x: m + barLength, y }, STYLES.cut, 1);
  for (let t = 0; t <= 50; t += 10) {
    const tx = m + t * ctx.scale;
    line(page, { x: tx, y }, { x: tx, y: y + 1.8 }, STYLES.cut, 1);
  }
  text(page, "0", m - 0.5, y - 3.4, 6, ctx.mono, 0.4);
  text(page, "50mm", m + barLength - 5, y - 3.4, 6, ctx.mono, 0.4);

  text(
    page,
    "ölçek %100 · sayfaya sığdırma KAPALI",
    m + barLength + 8,
    y - 0.8,
    7,
    ctx.mono,
    0.45,
  );

  const label = totalTiles > 0 ? `${code} / ${totalTiles}` : code;
  text(page, label, ctx.paper.width - m - 18, y - 0.8, 9, ctx.mono, 0.2);
}
ODK_EOF_4

echo "==> packages/print/src/print.test.ts"
cat > packages/print/src/print.test.ts << 'ODK_EOF_5'
import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { PDFDocument } from "pdf-lib";
import { mmToPt } from "@odk/geometry";
import { DEFAULT_PARAMS, generateCardHolder, buildInstructions } from "@odk/patterns";
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
import { packPieces, scaleFromMeasurement, STYLES } from "./layout.js";
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
    const layout = packPieces(pattern.pieces);
    const grid = planTiles(layout.width, layout.height);
    expect(doc.getPageCount()).toBe(2 + tileCount(grid));
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
    const rects = pattern.assembly.filter((a) => a.pieceId === "slot-rect");
    expect(rects).toHaveLength(1);
    expect(rects[0]?.layer).toBe(1);
  });

  it("en üstteki yuvanın üstü panel yüksekliğine TAM denk geliyor", () => {
    // Kademe dizilimi paneli tam doldurmalı: (n−1)·kademe + kart
    // yüksekliği + dikiş payı = panelHeight.
    //
    // DİKKAT: parça yükseklikleri KESİM ölçüsü (kalem payı iki kenardan
    // düşülmüş), montaj konumları ise nominal. Karşılaştırmada payı geri
    // eklemek gerekiyor; ilk yazdığımda bunu atlayıp 0.6mm'lik sahte bir
    // uyuşmazlık görmüştüm.
    const top = pattern.assembly.at(-1);
    const slotPiece = pattern.pieces.find((p) => p.id === "slot-t");
    const nominalHeight =
      (slotPiece?.height as number) + 2 * DEFAULT_PARAMS.penAllowance;
    expect((top?.y as number) + nominalHeight).toBeCloseTo(
      pattern.summary.panelHeight,
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
    const big = generateCardHolder({ ...DEFAULT_PARAMS, cardCount: 8 });
    const steps = buildInstructions(big, { ...DEFAULT_PARAMS, cardCount: 8 });
    expect(steps.length).toBeGreaterThan(8);
    const doc = await PDFDocument.load(
      await buildPatternPdf(big, FONTS, {
        params: { ...DEFAULT_PARAMS, cardCount: 8 },
      }),
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
ODK_EOF_5

echo "==> apps/web/src/engine.ts"
cat > apps/web/src/engine.ts << 'ODK_EOF_6'
/**
 * Motor köprüsü.
 *
 * Arayüzün motora tek giriş noktası. @odk/* paketlerinden doğrudan
 * import etmek yerine buradan geçmek, ileride motor API'si değiştiğinde
 * bileşenlerin değişmemesini sağlıyor.
 */
export {
  CATEGORIES,
  DEFAULT_PARAMS,
  FAMILIES,
  STATUS_LABEL,
  buildInstructions,
  categoryHasAvailable,
  familiesByCategory,
  generateCardHolder,
} from "@odk/patterns";

export { stitchSummary as stitchSummaryFor } from "@odk/geometry";
ODK_EOF_6

echo "==> apps/web/src/pdf.ts"
cat > apps/web/src/pdf.ts << 'ODK_EOF_7'
import type { PatternResult, CardHolderParams } from "@odk/patterns";
import { buildPatternPdf, scaleFromMeasurement } from "@odk/print";
import regularUrl from "@expo-google-fonts/ibm-plex-sans/400Regular/IBMPlexSans_400Regular.ttf?url";
import monoUrl from "@expo-google-fonts/jetbrains-mono/400Regular/JetBrainsMono_400Regular.ttf?url";

/**
 * Tarayıcı tarafı PDF köprüsü.
 *
 * Fontlar tembel yükleniyor: ~440KB'lık iki TTF'i ilk açılışta indirmek
 * gereksiz, kullanıcıların çoğu önce parametrelerle oynuyor. İlk PDF
 * isteğinde indirilip önbelleğe alınıyorlar.
 */

let cached: { regular: Uint8Array; mono: Uint8Array } | undefined;

async function loadFonts() {
  if (cached !== undefined) return cached;
  const [r, m] = await Promise.all([
    fetch(regularUrl).then((res) => res.arrayBuffer()),
    fetch(monoUrl).then((res) => res.arrayBuffer()),
  ]);
  cached = { regular: new Uint8Array(r), mono: new Uint8Array(m) };
  return cached;
}

export interface DownloadOptions {
  readonly printAllHoles: boolean;
  readonly scaleFactor: number;
  readonly title: string;
  /** Yapım adımları sayfası için gerekli. */
  readonly params: CardHolderParams;
}

export async function downloadPatternPdf(
  pattern: PatternResult,
  options: DownloadOptions,
): Promise<void> {
  const fonts = await loadFonts();
  const bytes = await buildPatternPdf(pattern, fonts, {
    printAllHoles: options.printAllHoles,
    scaleFactor: options.scaleFactor,
    title: options.title,
    version: new Date().toISOString().slice(0, 10),
    params: options.params,
  });

  const blob = new Blob([bytes as BlobPart], { type: "application/pdf" });
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = `${options.title.replace(/[^\wğüşıöçĞÜŞİÖÇ -]/g, "").trim()}.pdf`;
  document.body.appendChild(a);
  a.click();
  a.remove();
  URL.revokeObjectURL(url);
}

export { scaleFromMeasurement };
ODK_EOF_7

echo "==> apps/web/src/App.tsx"
cat > apps/web/src/App.tsx << 'ODK_EOF_8'
import { useMemo, useState } from "react";
import type {
  CardHolderParams,
  CardOrientation,
  SlotConstruction,
} from "@odk/patterns";
import {
  CATEGORIES,
  DEFAULT_PARAMS,
  buildInstructions,
  categoryHasAvailable,
  familiesByCategory,
  generateCardHolder,
  stitchSummaryFor,
  STATUS_LABEL,
} from "./engine.js";
import { PieceView } from "./PieceView.js";

/**
 * PDF katmanı DİNAMİK yükleniyor.
 *
 * pdf-lib + fontkit ana pakete girdiğinde bundle 1.29MB'a çıkıyordu.
 * Kullanıcıların çoğu önce parametrelerle oynuyor; PDF kodunu ilk
 * "PDF indir" tıklamasına kadar indirmemek ilk açılışı belirgin
 * hızlandırıyor.
 */
const pdfModule = () => import("./pdf.js");

const PX_PER_MM = 2.4;

interface SliderProps {
  label: string;
  value: number;
  min: number;
  max: number;
  step: number;
  unit?: string;
  hint?: string;
  onChange: (v: number) => void;
}

function Slider({ label, value, min, max, step, unit, hint, onChange }: SliderProps) {
  const id = `f-${label.replace(/\s/g, "-")}`;
  return (
    <div className="field">
      <div className="field-head">
        <label htmlFor={id}>{label}</label>
        <span className="field-value">
          {step < 1 ? value.toFixed(1) : value}
          {unit ?? ""}
        </span>
      </div>
      <input
        id={id}
        type="range"
        min={min}
        max={max}
        step={step}
        value={value}
        onChange={(e) => onChange(Number(e.target.value))}
      />
      {hint !== undefined && <p className="hint">{hint}</p>}
    </div>
  );
}

interface ChoiceProps<T extends string> {
  label: string;
  value: T;
  options: readonly { value: T; label: string }[];
  hint?: string;
  onChange: (v: T) => void;
}

function Choice<T extends string>({
  label,
  value,
  options,
  hint,
  onChange,
}: ChoiceProps<T>) {
  return (
    <div className="field">
      <div className="field-head">
        <label>{label}</label>
      </div>
      <div className="segmented" role="group" aria-label={label}>
        {options.map((o) => (
          <button
            key={o.value}
            type="button"
            aria-pressed={o.value === value}
            onClick={() => onChange(o.value)}
          >
            {o.label}
          </button>
        ))}
      </div>
      {hint !== undefined && <p className="hint">{hint}</p>}
    </div>
  );
}

interface PrintState {
  readonly printAllHoles: boolean;
  readonly measured: string;
  readonly scaleFactor: number;
  readonly note: string;
  readonly noteOk: boolean;
  readonly busy: boolean;
}

const INITIAL_PRINT: PrintState = {
  printAllHoles: true,
  measured: "50",
  scaleFactor: 1,
  note: "",
  noteOk: true,
  busy: false,
};

interface SelectProps {
  label: string;
  value: string;
  options: readonly { value: string; label: string }[];
  hint?: string;
  onChange: (v: string) => void;
}

function Select({ label, value, options, hint, onChange }: SelectProps) {
  const id = `s-${label.replace(/\s/g, "-")}`;
  return (
    <div className="field">
      <div className="field-head">
        <label htmlFor={id}>{label}</label>
      </div>
      <select
        id={id}
        className="dropdown"
        value={value}
        onChange={(e) => onChange(e.target.value)}
      >
        {options.map((o) => (
          <option key={o.value} value={o.value}>
            {o.label}
          </option>
        ))}
      </select>
      {hint !== undefined && <p className="hint">{hint}</p>}
    </div>
  );
}

export default function App() {
  const [params, setParams] = useState<CardHolderParams>(DEFAULT_PARAMS);
  const [print, setPrint] = useState<PrintState>(INITIAL_PRINT);

  const set = <K extends keyof CardHolderParams>(
    key: K,
    value: CardHolderParams[K],
  ) => setParams((p) => ({ ...p, [key]: value }));

  const result = useMemo(() => {
    try {
      return { ok: true as const, value: generateCardHolder(params) };
    } catch (err) {
      return {
        ok: false as const,
        message: err instanceof Error ? err.message : String(err),
      };
    }
  }, [params]);

  return (
    <div className="shell">
      <aside className="rail">
        <header className="masthead">
          <h1>Deri Kalıp Motoru</h1>
          <p>
            Kartlık · kesit çözücü + dikiş dağıtıcı
            <br />
            ölçüler mm · ızgara 10mm, kalın çizgi 50mm
          </p>
        </header>

        <div className="group">
          <span className="group-title">Katalog</span>
          {CATEGORIES.map((c) => (
            <div className="cat" key={c.id}>
              <span className="cat-name">{c.name}</span>
              <ul className="fam">
                {familiesByCategory(c.id).map((f) => (
                  <li
                    key={f.id}
                    className="fam-item"
                    data-status={f.status}
                    aria-disabled={f.status !== "hazir"}
                  >
                    <span>{f.name}</span>
                    <span className="fam-status">{STATUS_LABEL[f.status]}</span>
                  </li>
                ))}
              </ul>
              {!categoryHasAvailable(c.id) && (
                <p className="hint">{c.description}</p>
              )}
            </div>
          ))}
        </div>

        <fieldset className="group" style={{ border: 0, margin: 0, padding: 0 }}>
          <legend>Yuvalar</legend>
          <Slider
            label="Kart yuvası"
            value={params.cardCount}
            min={1}
            max={8}
            step={1}
            onChange={(v) => set("cardCount", v)}
          />
          <Choice<SlotConstruction>
            label="Yapım biçimi"
            value={params.construction}
            options={[
              { value: "t-slot", label: "T-slot" },
              { value: "stacked", label: "Düz yığın" },
            ]}
            hint="T-slot kenar kalınlığını yuva sayısından bağımsız tutar."
            onChange={(v) => set("construction", v)}
          />
          <Choice<CardOrientation>
            label="Kart yönü"
            value={params.orientation}
            options={[
              { value: "horizontal", label: "Yatay" },
              { value: "vertical", label: "Dikey" },
            ]}
            onChange={(v) => set("orientation", v)}
          />
          <Slider
            label="Kademe"
            value={params.reveal}
            min={5}
            max={22}
            step={0.5}
            unit="mm"
            hint="Yuva ağızları arası mesafe. 5mm belgelenmiş alt sınır."
            onChange={(v) => set("reveal", v)}
          />
        </fieldset>

        <fieldset className="group" style={{ border: 0, margin: 0, padding: 0 }}>
          <legend>Deri</legend>
          <Slider
            label="Dış kabuk"
            value={params.outerThickness}
            min={0.6}
            max={1.6}
            step={0.1}
            unit="mm"
            onChange={(v) => set("outerThickness", v)}
          />
          <Slider
            label="Yuva derisi"
            value={params.slotThickness}
            min={0.4}
            max={1.2}
            step={0.1}
            unit="mm"
            hint="Önerilen 0.6–0.8mm. Kalın deri yuvanın esnemesini engeller."
            onChange={(v) => set("slotThickness", v)}
          />
        </fieldset>

        <fieldset className="group" style={{ border: 0, margin: 0, padding: 0 }}>
          <legend>Dikiş ve kesim</legend>
          <Select
            label="Pricking iron"
            value={params.pitch === undefined ? "auto" : String(params.pitch)}
            options={[
              { value: "2.7", label: "2.7 mm" },
              { value: "3", label: "3.0 mm" },
              { value: "3.38", label: "3.38 mm" },
              { value: "3.85", label: "3.85 mm" },
              { value: "4", label: "4.0 mm" },
              { value: "5", label: "5.0 mm" },
              { value: "auto", label: "Oto — en az delik" },
            ]}
            hint="Elindeki takımın adımını seç. Oto yalnızca sapmayı ölçebilir, dikişin sıklığı senin kararın."
            onChange={(v) =>
              setParams((p) => {
                if (v === "auto") {
                  const { pitch: _drop, ...rest } = p;
                  return rest;
                }
                return { ...p, pitch: Number(v) };
              })
            }
          />
          <Slider
            label="Dikiş payı"
            value={params.stitchMargin}
            min={2.5}
            max={5}
            step={0.5}
            unit="mm"
            onChange={(v) => set("stitchMargin", v)}
          />
          <Slider
            label="Köşe yarıçapı"
            value={params.cornerRadius}
            min={0}
            max={10}
            step={0.5}
            unit="mm"
            onChange={(v) => set("cornerRadius", v)}
          />
          <Choice<string>
            label="Kalem payı"
            value={String(params.penAllowance)}
            options={[
              { value: "0", label: "0" },
              { value: "0.3", label: "0.3mm" },
              { value: "0.5", label: "0.5mm" },
            ]}
            hint="Kalem ucu dışa kaçtığı için şablon o kadar küçük basılır."
            onChange={(v) => set("penAllowance", Number(v))}
          />
        </fieldset>

        <fieldset className="group" style={{ border: 0, margin: 0, padding: 0 }}>
          <legend>Baskı</legend>

          <Choice<string>
            label="Delikler"
            value={print.printAllHoles ? "all" : "anchors"}
            options={[
              { value: "anchors", label: "Sadece köşe" },
              { value: "all", label: "Hepsi" },
            ]}
            hint="Şablonu deriye bantlayıp noktalardan deleceksen 'Hepsi'. Ironu kendin yürüteceksen köşe çapaları yeterli."
            onChange={(v) =>
              setPrint((p) => ({ ...p, printAllHoles: v === "all" }))
            }
          />

          <div className="field">
            <div className="field-head">
              <label htmlFor="cal">Ölçtüğün kare</label>
              <span className="field-value">nominal 50mm</span>
            </div>
            <div className="calibrate">
              <input
                id="cal"
                type="number"
                step="0.1"
                min="1"
                value={print.measured}
                onChange={(e) =>
                  setPrint((p) => ({ ...p, measured: e.target.value }))
                }
              />
              <button
                type="button"
                onClick={() => {
                  void pdfModule().then(({ scaleFromMeasurement }) => {
                    const r = scaleFromMeasurement(Number(print.measured));
                    setPrint((p) => ({
                      ...p,
                      scaleFactor: r.ok ? r.factor : p.scaleFactor,
                      note: r.message,
                      noteOk: r.ok,
                    }));
                  });
                }}
              >
                Uygula
              </button>
            </div>
            <p className="hint">
              PDF'i bas, kapaktaki kareyi cetvelle ölç, çıkan değeri buraya
              gir. Ölçek düzeltilir.
            </p>
            {print.note !== "" && (
              <p className="hint" data-tone={print.noteOk ? "ok" : "bad"}>
                {print.note}
              </p>
            )}
          </div>

          <button
            type="button"
            className="primary"
            disabled={print.busy || !result.ok}
            onClick={() => {
              if (!result.ok) return;
              setPrint((p) => ({ ...p, busy: true }));
              pdfModule()
                .then(({ downloadPatternPdf }) =>
                  downloadPatternPdf(result.value, {
                    printAllHoles: print.printAllHoles,
                    scaleFactor: print.scaleFactor,
                    title: `Kartlık ${params.cardCount} yuva`,
                    params,
                  }),
                )
                .catch((err: unknown) => {
                  setPrint((p) => ({
                    ...p,
                    note:
                      "PDF üretilemedi: " +
                      (err instanceof Error ? err.message : String(err)),
                    noteOk: false,
                  }));
                })
                .finally(() => setPrint((p) => ({ ...p, busy: false })));
            }}
          >
            {print.busy ? "Hazırlanıyor…" : "PDF indir"}
          </button>
          {print.scaleFactor !== 1 && (
            <p className="hint">
              Ölçek düzeltmesi aktif: ×{print.scaleFactor.toFixed(4)}
            </p>
          )}
        </fieldset>
      </aside>

      <main className="stage">
        {!result.ok ? (
          <ul className="diagnostics">
            <li className="diagnostic" data-severity="error">
              <code>ÇÖZÜLEMEDİ</code>
              <span>
                Bu parametrelerle kalıp üretilemiyor: {result.message}
                {" "}Dikiş payını küçültmeyi ya da yuva sayısını azaltmayı dene.
              </span>
            </li>
          </ul>
        ) : (
          <Result value={result.value} params={params} />
        )}
      </main>
    </div>
  );
}

function Result({
  value,
  params,
}: {
  value: ReturnType<typeof generateCardHolder>;
  params: CardHolderParams;
}) {
  const s = value.summary;
  const outer = value.pieces.find((p) => p.id === "outer");

  return (
    <>
      {value.diagnostics.length > 0 && (
        <ul className="diagnostics">
          {value.diagnostics.map((d, i) => (
            <li key={i} className="diagnostic" data-severity={d.severity}>
              <code>{d.code}</code>
              <span>{d.message}</span>
            </li>
          ))}
        </ul>
      )}

      <div className="stage-head">
        <h2>Parçalar</h2>
        <span className="scale-note">
          {params.cardCount} yuva · {params.construction === "t-slot" ? "T-slot" : "düz yığın"} ·{" "}
          {s.pitch}mm adım · {s.totalHoles} delik
        </span>
      </div>

      <div className="legend">
        <span>
          <i className="swatch" style={{ borderTopColor: "var(--bone)" }} /> kesim
        </span>
        <span>
          <i
            className="swatch"
            style={{ borderTopColor: "var(--brass-dim)", borderTopStyle: "dashed" }}
          />{" "}
          dikiş hattı
        </span>
        <span>
          <i
            className="swatch"
            style={{ borderTopColor: "var(--chalk)", borderTopStyle: "dotted" }}
          />{" "}
          kat
        </span>
        <span>
          <i className="swatch dot" /> delik
        </span>
      </div>

      {value.pieces.map((piece) => (
        <section className="piece" key={piece.id}>
          <div className="piece-head">
            <span className="piece-name">{piece.name}</span>
            <span className="piece-meta">
              ×{piece.quantity} · {piece.width.toFixed(1)} × {piece.height.toFixed(1)}mm ·{" "}
              {piece.leatherThickness.toFixed(1)}mm deri
            </span>
          </div>
          <PieceView piece={piece} pxPerMm={PX_PER_MM} />
        </section>
      ))}

      <section className="steps">
        <h3>Yapım adımları</h3>
        <ol>
          {buildInstructions(value, params).map((step) => (
            <li key={step.n}>
              <span className="step-title">{step.title}</span>
              <p>{step.body}</p>
              {step.warning !== undefined && (
                <p className="step-warn">{step.warning}</p>
              )}
            </li>
          ))}
        </ol>
      </section>

      <div className="columns">
        <table className="readout">
          <caption>Kesit çözümü</caption>
          <tbody>
            {value.crossSection.layers.map((l) => (
              <tr key={l.layerId}>
                <th scope="row">{l.name}</th>
                <td className="num">{l.straightLength.toFixed(2)}</td>
                <td className="num">+{l.bendAllowance.toFixed(2)}</td>
                <td className="num">= {l.flatLength.toFixed(2)} mm</td>
              </tr>
            ))}
          </tbody>
        </table>

        <table className="readout">
          <caption>Ölçüler</caption>
          <tbody>
            <tr>
              <th scope="row">bölme genişliği</th>
              <td className="num">{s.compartmentWidth.toFixed(1)} mm</td>
            </tr>
            <tr>
              <th scope="row">yuva yığını</th>
              <td className="num">{s.slotStackHeight.toFixed(1)} mm</td>
            </tr>
            <tr>
              <th scope="row">kat payı</th>
              <td className="num">{s.foldAllowance.toFixed(2)} mm</td>
            </tr>
            <tr>
              <th scope="row">kapalı kalınlık</th>
              <td className="num">{s.closedThickness.toFixed(2)} mm</td>
            </tr>
            <tr>
              <th scope="row">kart yüklü</th>
              <td className="num">{s.loadedThickness.toFixed(2)} mm</td>
            </tr>
            <tr>
              <th scope="row">kenar kalınlığı</th>
              <td className="num">{s.edgeThickness.toFixed(2)} mm</td>
            </tr>
            <tr>
              <th scope="row">A4</th>
              <td className="num">{s.fitsA4 ? "sığıyor" : "bölünecek"}</td>
            </tr>
          </tbody>
        </table>

        {outer?.stitchPlan !== undefined && (
          <table className="readout">
            <caption>Dikiş planı — dış kabuk</caption>
            <tbody>
              {stitchSummaryFor(outer.stitchPlan).map((line, i) => (
                <tr key={i}>
                  <td colSpan={2}>{line}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>
    </>
  );
}
ODK_EOF_8

echo "==> apps/web/src/styles.css"
cat > apps/web/src/styles.css << 'ODK_EOF_9'
/*
  TASARIM NOTU
  ────────────────────────────────────────────────────────────────────
  Bu bir alet, tanıtım sayfası değil. Palet konunun kendi dünyasından:
  deri işçisinin gün boyu baktığı şey kesim matı. Koyu yeşil mat, üstünde
  bone beyazı kesim hatları, pirinç renginde dikiş delikleri.

  Mat ızgarası süs değil ÖLÇÜM ARACI: 10mm aralıklı, kalın çizgiler 50mm.
  Yani ekrandaki ızgara, kullanıcının masasındaki matın aynısı ve ölçek
  referansı olarak okunabiliyor.

  Tipografi: her sayı monospace (IBM Plex Mono) — ölçüler hizalanmalı ve
  rakamlar eşit genişlikte olmalı ki 93.4 ile 103.4 yan yana okunabilsin.
  Etiketler condensed sans, çünkü dar kontrol rayında yer dar.
*/

:root {
  --mat: #14312b;
  --mat-deep: #0e2420;
  --mat-grid: #1d443b;
  --mat-grid-major: #2a5f52;

  --panel: #0b1c19;
  --panel-edge: #1c3a34;

  --bone: #f2efe6;
  --bone-dim: #a8b5ae;
  --bone-faint: #6d8079;

  --brass: #e0a458;
  --brass-dim: #8a6535;
  --chalk: #6fb3a0;

  --warn: #d9973f;
  --error: #d9634f;

  /* JetBrains Mono: PDF katmanıyla aynı font. IBM Plex Mono
     @pdf-lib/fontkit ile boşluk karakterinde patlıyor (bkz.
     packages/print/src/print.test.ts), ekran ve baskı ayrışmasın diye
     ikisi de buna geçti. */
  --mono: "JetBrains Mono", ui-monospace, "SFMono-Regular", monospace;
  --sans: "IBM Plex Sans Condensed", system-ui, -apple-system, sans-serif;

  --rail: 320px;
}

* {
  box-sizing: border-box;
}

html,
body {
  margin: 0;
  padding: 0;
  background: var(--panel);
  color: var(--bone);
  font-family: var(--sans);
  -webkit-font-smoothing: antialiased;
}

body {
  min-height: 100vh;
}

/* ── Kabuk ─────────────────────────────────────────────────────────── */

.shell {
  display: grid;
  grid-template-columns: var(--rail) 1fr;
  min-height: 100vh;
}

.rail {
  background: var(--panel);
  border-right: 1px solid var(--panel-edge);
  padding: 20px 18px 40px;
  overflow-y: auto;
}

.stage {
  background: var(--mat-deep);
  padding: 20px 24px 60px;
  overflow-x: auto;
}

@media (max-width: 860px) {
  .shell {
    grid-template-columns: 1fr;
  }
  .rail {
    border-right: none;
    border-bottom: 1px solid var(--panel-edge);
  }
}

/* ── Başlık ────────────────────────────────────────────────────────── */

.masthead {
  margin-bottom: 26px;
}

.masthead h1 {
  font-size: 19px;
  font-weight: 700;
  letter-spacing: 0.02em;
  margin: 0 0 4px;
}

.masthead p {
  font-family: var(--mono);
  font-size: 11px;
  line-height: 1.5;
  color: var(--bone-faint);
  margin: 0;
}

/* ── Kontroller ────────────────────────────────────────────────────── */

.group {
  margin-bottom: 22px;
}

.group > legend,
.group-title {
  font-family: var(--mono);
  font-size: 10px;
  letter-spacing: 0.14em;
  text-transform: uppercase;
  color: var(--bone-faint);
  margin: 0 0 10px;
  padding: 0;
  display: block;
}

.field {
  margin-bottom: 14px;
}

.field-head {
  display: flex;
  justify-content: space-between;
  align-items: baseline;
  margin-bottom: 5px;
}

.field-head label {
  font-size: 13px;
  color: var(--bone-dim);
}

.field-value {
  font-family: var(--mono);
  font-size: 12px;
  color: var(--bone);
}

input[type="range"] {
  width: 100%;
  height: 20px;
  appearance: none;
  background: transparent;
  cursor: pointer;
}

input[type="range"]::-webkit-slider-runnable-track {
  height: 2px;
  background: var(--panel-edge);
}

input[type="range"]::-moz-range-track {
  height: 2px;
  background: var(--panel-edge);
}

input[type="range"]::-webkit-slider-thumb {
  appearance: none;
  width: 13px;
  height: 13px;
  margin-top: -5.5px;
  background: var(--brass);
  border: none;
  border-radius: 0;
  transform: rotate(45deg);
}

input[type="range"]::-moz-range-thumb {
  width: 13px;
  height: 13px;
  background: var(--brass);
  border: none;
  border-radius: 0;
}

input[type="range"]:focus-visible {
  outline: 2px solid var(--chalk);
  outline-offset: 4px;
}

.segmented {
  display: flex;
  gap: 1px;
  background: var(--panel-edge);
  border: 1px solid var(--panel-edge);
}

.segmented button {
  flex: 1;
  background: var(--panel);
  color: var(--bone-dim);
  border: none;
  padding: 7px 4px;
  font-family: var(--sans);
  font-size: 12px;
  cursor: pointer;
}

.segmented button[aria-pressed="true"] {
  background: var(--brass);
  color: var(--mat-deep);
  font-weight: 600;
}

.segmented button:focus-visible {
  outline: 2px solid var(--chalk);
  outline-offset: -2px;
}

.hint {
  font-family: var(--mono);
  font-size: 10px;
  line-height: 1.5;
  color: var(--bone-faint);
  margin: 5px 0 0;
}

/* ── Tanılama ──────────────────────────────────────────────────────── */

.diagnostics {
  margin: 0 0 20px;
  padding: 0;
  list-style: none;
}

.diagnostic {
  display: flex;
  gap: 9px;
  padding: 9px 11px;
  margin-bottom: 6px;
  font-size: 13px;
  line-height: 1.45;
  background: var(--panel);
  border-left: 2px solid var(--bone-faint);
}

.diagnostic[data-severity="warning"] {
  border-left-color: var(--warn);
}

.diagnostic[data-severity="error"] {
  border-left-color: var(--error);
}

.diagnostic code {
  font-family: var(--mono);
  font-size: 10px;
  letter-spacing: 0.06em;
  color: var(--bone-faint);
  white-space: nowrap;
  padding-top: 2px;
}

/* ── Sahne ─────────────────────────────────────────────────────────── */

.stage-head {
  display: flex;
  flex-wrap: wrap;
  gap: 8px 22px;
  align-items: baseline;
  margin-bottom: 16px;
}

.stage-head h2 {
  font-size: 15px;
  font-weight: 600;
  margin: 0;
  letter-spacing: 0.02em;
}

.scale-note {
  font-family: var(--mono);
  font-size: 11px;
  color: var(--bone-faint);
}

.piece {
  margin-bottom: 30px;
}

.piece-head {
  display: flex;
  flex-wrap: wrap;
  gap: 6px 16px;
  align-items: baseline;
  margin-bottom: 8px;
}

.piece-name {
  font-size: 14px;
  font-weight: 600;
}

.piece-meta {
  font-family: var(--mono);
  font-size: 11px;
  color: var(--bone-dim);
}

.piece-canvas {
  background: var(--mat);
  border: 1px solid var(--mat-grid-major);
  display: block;
  max-width: 100%;
  height: auto;
}

/* ── Tablolar ──────────────────────────────────────────────────────── */

.readout {
  border-collapse: collapse;
  font-family: var(--mono);
  font-size: 12px;
  margin-bottom: 26px;
  min-width: 260px;
}

.readout caption {
  font-size: 10px;
  letter-spacing: 0.14em;
  text-transform: uppercase;
  color: var(--bone-faint);
  text-align: left;
  padding-bottom: 8px;
}

.readout th,
.readout td {
  text-align: left;
  padding: 5px 22px 5px 0;
  border-bottom: 1px solid var(--panel-edge);
  font-weight: 400;
}

.readout th {
  color: var(--bone-faint);
}

.readout td {
  color: var(--bone);
  font-variant-numeric: tabular-nums;
}

.readout td.num {
  text-align: right;
  padding-right: 0;
}

.columns {
  display: flex;
  flex-wrap: wrap;
  gap: 0 48px;
}

/* ── Açıklama ──────────────────────────────────────────────────────── */

.legend {
  display: flex;
  flex-wrap: wrap;
  gap: 6px 20px;
  font-family: var(--mono);
  font-size: 11px;
  color: var(--bone-dim);
  margin-bottom: 18px;
}

.legend span {
  display: flex;
  align-items: center;
  gap: 7px;
}

.swatch {
  width: 20px;
  height: 0;
  border-top-width: 2px;
  border-top-style: solid;
}

.swatch.dot {
  width: 7px;
  height: 7px;
  border: none;
  border-radius: 50%;
  background: var(--brass);
}

@media (prefers-reduced-motion: reduce) {
  * {
    transition: none !important;
    animation: none !important;
  }
}

/* ── Baskı paneli ──────────────────────────────────────────────────── */

.calibrate {
  display: flex;
  gap: 6px;
}

.calibrate input {
  flex: 1;
  min-width: 0;
  background: var(--mat-deep);
  border: 1px solid var(--panel-edge);
  color: var(--bone);
  font-family: var(--mono);
  font-size: 13px;
  padding: 6px 8px;
}

.calibrate input:focus-visible,
.calibrate button:focus-visible,
button.primary:focus-visible {
  outline: 2px solid var(--chalk);
  outline-offset: 2px;
}

.calibrate button {
  background: var(--panel);
  border: 1px solid var(--panel-edge);
  color: var(--bone-dim);
  font-family: var(--sans);
  font-size: 12px;
  padding: 6px 12px;
  cursor: pointer;
}

.calibrate button:hover {
  border-color: var(--brass-dim);
  color: var(--bone);
}

button.primary {
  width: 100%;
  margin-top: 4px;
  background: var(--brass);
  color: var(--mat-deep);
  border: none;
  padding: 11px;
  font-family: var(--sans);
  font-size: 14px;
  font-weight: 600;
  letter-spacing: 0.02em;
  cursor: pointer;
}

button.primary:disabled {
  background: var(--panel-edge);
  color: var(--bone-faint);
  cursor: not-allowed;
}

.hint[data-tone="ok"] {
  color: var(--chalk);
}

.hint[data-tone="bad"] {
  color: var(--error);
}

.dropdown {
  width: 100%;
  background: var(--mat-deep);
  border: 1px solid var(--panel-edge);
  color: var(--bone);
  font-family: var(--mono);
  font-size: 13px;
  padding: 7px 8px;
  cursor: pointer;
}

.dropdown:focus-visible {
  outline: 2px solid var(--chalk);
  outline-offset: 2px;
}

/* ── Katalog ───────────────────────────────────────────────────────── */

.cat {
  margin-bottom: 12px;
}

.cat-name {
  font-size: 13px;
  font-weight: 600;
  color: var(--bone);
}

.fam {
  list-style: none;
  margin: 4px 0 0;
  padding: 0;
}

.fam-item {
  display: flex;
  justify-content: space-between;
  gap: 8px;
  padding: 4px 0 4px 9px;
  border-left: 1px solid var(--panel-edge);
  font-size: 12px;
  color: var(--bone-faint);
}

.fam-item[data-status="hazir"] {
  border-left-color: var(--brass);
  color: var(--bone);
}

.fam-status {
  font-family: var(--mono);
  font-size: 10px;
  color: var(--bone-faint);
  white-space: nowrap;
}

.fam-item[data-status="hazir"] .fam-status {
  color: var(--brass);
}

/* ── Yapım adımları ────────────────────────────────────────────────── */

.steps {
  max-width: 640px;
  margin-bottom: 32px;
}

.steps h3 {
  font-size: 14px;
  font-weight: 600;
  margin: 0 0 12px;
}

.steps ol {
  margin: 0;
  padding: 0;
  list-style: none;
  counter-reset: step;
}

.steps li {
  counter-increment: step;
  position: relative;
  padding: 0 0 16px 30px;
  border-left: 1px solid var(--panel-edge);
  margin-left: 8px;
}

.steps li::before {
  content: counter(step);
  position: absolute;
  left: -9px;
  top: 0;
  width: 18px;
  height: 18px;
  background: var(--mat-deep);
  border: 1px solid var(--panel-edge);
  color: var(--bone-dim);
  font-family: var(--mono);
  font-size: 10px;
  display: flex;
  align-items: center;
  justify-content: center;
}

.steps li:last-child {
  border-left-color: transparent;
}

.step-title {
  font-size: 13px;
  font-weight: 600;
  color: var(--bone);
}

.steps p {
  margin: 4px 0 0;
  font-size: 13px;
  line-height: 1.5;
  color: var(--bone-dim);
}

.step-warn {
  border-left: 2px solid var(--warn);
  padding-left: 9px;
  margin-top: 7px !important;
  color: var(--bone) !important;
  font-size: 12px !important;
}
ODK_EOF_9

echo "==> Testler"
pnpm test

echo "==> Typecheck"
pnpm typecheck

echo "==> Arayuz derlemesi"
pnpm --filter @odk/web build

cat << 'ODK_DONE'

============================================================
KATALOG + YAPIM ADIMLARI
============================================================

PDF: kapak -> montaj -> ADIMLAR -> desen sayfalari  (6 sayfa)
Arayuz: sol rayda katalog, sahnede adim listesi

Git:
  git add -A
  git commit -m "Kalip katalogu ve yapim adimlari

KATALOG
- 4 kategori: kartlik, cuzdan, canta, aksesuar
- 7 urun ailesi, durum isaretli (hazir / planlandi)
- DURUSTLUK TESTI: availableFamilies() yalnizca gercekten uretilebilen
  aileyi dondurur. Liste buyurse jeneratoru de eklenmis olmali; var
  olmayan bir aileyi hazir gostermek kullanicinin zamanini calar.

YAPIM ADIMLARI
- Adimlar SABIT METIN DEGIL, kaliptan turetiliyor: parca sayisi, delik
  adedi, kademe, tutkal bandi genisligi, kat bolgesi hepsi hesaptan.
  Kart sayisi degisince talimat da degisiyor (test ile sabitlendi).
- Kritik uyarilar: tutkal dikis hattinin icine tasarsa yuva yapisir;
  kat bolgesine tutkal surulurse cuzdan katlanmaz; kenar bitirme
  dikisten ONCE yapilir; damar yonu ayni olmali.
- PDF'te ayri sayfa, tasma metin uzunluguna gore hesaplaniyor
  (sabit 'sayfa basina N adim' varsayimi yok)
- 275 test geciyor"

  git push
  vercel --prod
ODK_DONE
