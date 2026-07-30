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
