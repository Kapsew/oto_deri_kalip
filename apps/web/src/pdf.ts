import type { PatternResult, InstructionContext } from "@odk/patterns";
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
  readonly params: InstructionContext;
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
