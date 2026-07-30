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
