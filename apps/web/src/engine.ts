/**
 * Motor köprüsü.
 *
 * Arayüzün motora tek giriş noktası. @odk/* paketlerinden doğrudan
 * import etmek yerine buradan geçmek, ileride motor API'si değiştiğinde
 * bileşenlerin değişmemesini sağlıyor.
 */
export {
  BIFOLD_DEFAULTS,
  BANKNOTES,
  CATEGORIES,
  DEFAULT_PARAMS,
  FAMILIES,
  STATUS_LABEL,
  buildInstructions,
  categoryHasAvailable,
  familiesByCategory,
  generateBifold,
  generateCardHolder,
  generateTote,
  STRAP_SPECS,
  TOTE_DEFAULTS,
  DEFAULT_RATES,
  costNotes,
  estimateCost,
  DEFAULT_TIME_MODEL,
} from "@odk/patterns";

export { stitchSummary as stitchSummaryFor } from "@odk/geometry";
