import type { Mm } from "@odk/geometry";
import type { PatternResult } from "./cardholder.js";
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

/**
 * Adım üretimi için gereken asgari parametreler.
 *
 * Tam parametre tipi (CardHolderParams / BifoldParams) yerine bu dar
 * arayüz kullanılıyor: yapısal tipleme sayesinde her iki aile de
 * doğrudan geçebiliyor ve yeni bir aile eklendiğinde bu dosyaya
 * dokunmak gerekmiyor.
 */
export interface InstructionContext {
  readonly penAllowance: Mm;
  readonly stitchMargin: Mm;
  /** Cüzdanlarda yuva kademesi; çantada yok. */
  readonly reveal?: Mm;
  /**
   * Hangi adım dizisi kullanılacak.
   *
   * Cüzdan adımları ("yuvaları kademeyle diz") çantada anlamsız;
   * çantanın kendi kritik hataları var (körüğü kaydırmak, askı dikişi).
   * Tek bir metin ikisine birden uydurulamaz.
   */
  readonly kind?: "cuzdan" | "canta";
}

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
  params: InstructionContext,
): InstructionStep[] {
  if (params.kind === "canta") return buildBagInstructions(pattern, params);
  return buildWalletInstructions(pattern, params);
}

function buildWalletInstructions(
  pattern: PatternResult,
  params: InstructionContext,
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
    `En alttan başla. Yuvaları ${params.reveal ?? 12}mm kademeyle diz: ` +
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


// --- Çanta adımları --------------------------------------------------------

/**
 * Çantanın kritik hataları cüzdanınkinden farklı.
 *
 * Cüzdanda felaket tutkalın yuvaya taşması. Çantada körüğün panele
 * kaydırılarak dikilmesi: körük uzunluğu panel hattının yay uzunluğuna
 * göre TAM hesaplandığı için, bir uçtan başlayıp çekiştirerek dikmek
 * diğer uçta fazlalık ya da eksiklik bırakır ve çanta çarpık oturur.
 */
function buildBagInstructions(
  pattern: PatternResult,
  params: InstructionContext,
): InstructionStep[] {
  const s = pattern.summary;
  const steps: InstructionStep[] = [];
  let n = 0;
  const add = (title: string, body: string, warning?: string): void => {
    n += 1;
    steps.push(warning === undefined ? { n, title, body } : { n, title, body, warning });
  };

  const pieceList = pattern.pieces.map((p) => `${p.code} ×${p.quantity}`).join(", ");
  const total = pattern.pieces.reduce((a, p) => a + p.quantity, 0);
  const metric = (label: string): string | undefined =>
    s.metrics?.find((m) => m.label === label)?.value;

  add(
    "Ölçeği doğrula",
    "Kapak sayfasındaki 50mm kareyi cetvelle ölç. 50mm değilse ölçtüğün " +
      "değeri uygulamaya gir, PDF'i yeniden indir ve aynı yazıcı ayarıyla bas.",
    "Bu adımı atlarsan körük uzunluğu panele oturmaz; çanta köşelerden buruşur.",
  );

  add(
    "Kağıt parçaları kes",
    `Toplam ${total} parça: ${pieceList}. Kesim çizgisini kağıtta bırak, ` +
      `dışından kes. Büyük parçalar birden fazla sayfaya bölünmüşse önce ` +
      `sayfaları haçlardan hizalayıp yapıştır.`,
  );

  add(
    "Deriyi kes",
    `Panel ve körük parçalarını damar yönü aynı olacak şekilde yerleştir ve kes. ` +
      `Körük uzunluğu ${metric("körük uzunluğu") ?? "?"}; bu değer panelin dikiş ` +
      `hattının yay uzunluğundan hesaplandı, kısaltma ya da uzatma yapma.`,
    "Askı en çok yük taşıyan parça: postun en sağlam bölgesinden (sırt) ve " +
      "damar yönünde kes. Karın bölgesinden kesilen askı zamanla uzar.",
  );

  add(
    "Delikleri işaretle",
    `${s.pitch}mm pricking iron, panel başına ${s.totalHoles} delik. ` +
      `Körüğün iki uzun kenarındaki delikler panelin delikleriyle birebir ` +
      `aynı mesafelerde; kalıptan işaretle, kendin sayma.`,
  );

  add(
    "Körüğü panele hizala",
    `Körüğün ORTASINI panelin taban ortasıyla eşle ve oradan iki yana doğru ` +
      `iğneleyerek ilerle. Köşe yayında deriyi hafifçe kıvırarak yürüt.`,
    "Bir uçtan başlayıp çekiştirerek dikme. Körük uzunluğu tam hesaplandı; " +
      "gerilerek dikilirse diğer uçta fazlalık kalır ve çanta çarpık oturur. " +
      "İkinci paneli dikmeden önce birinci tarafın düzgün oturduğunu kontrol et — " +
      "sonradan sökmek deriyi delik deliğe bırakır.",
  );

  add(
    "Dik",
    `Eyer dikişi ile önce körük–ön panel, sonra körük–arka panel. ` +
      `Toplam ${s.totalHoles * 2} delikten geçilecek.`,
  );

  const strapMetric = s.metrics?.find((m) => m.label.includes("askı") || m.label.includes("sap"));
  if (strapMetric !== undefined) {
    add(
      "Askıyı bağla",
      `${strapMetric.label}: ${strapMetric.value}. Uçları çantanın yan üst ` +
        `köşelerine bindirip dik.`,
      "Askı dikişini çift sıra ya da X dikiş yap. Tek sıra düz dikiş, " +
        "çantanın tüm ağırlığını birkaç deliğe yükler ve deri o noktadan yırtılır.",
    );
  }

  add(
    "Kenarları bitir",
    "Kenarları zımparala, kenar boyası ya da cila uygula.",
    "Kenar bitirme dikişten SONRA yapılır — cüzdanın tersi. Çantada kenarlar " +
      "körük ve panel katmanlarından oluşuyor; dikilmeden hizalanamaz.",
  );

  add(
    "Kontrol et",
    `Hacim ${metric("hacim") ?? "?"}, derinlik ${s.closedThickness.toFixed(0)}mm. ` +
      `Çanta boşken kendi başına dik durmalı; sarkıyorsa panel derisi ince kalmış.`,
  );

  return steps;
}
