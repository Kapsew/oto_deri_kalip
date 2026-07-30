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
