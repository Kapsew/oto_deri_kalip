/**
 * Motor köprüsü.
 *
 * Arayüzün motora tek giriş noktası. @odk/* paketlerinden doğrudan
 * import etmek yerine buradan geçmek, ileride motor API'si değiştiğinde
 * bileşenlerin değişmemesini sağlıyor.
 */
export {
  DEFAULT_PARAMS,
  generateCardHolder,
} from "@odk/patterns";

export { stitchSummary as stitchSummaryFor } from "@odk/geometry";
