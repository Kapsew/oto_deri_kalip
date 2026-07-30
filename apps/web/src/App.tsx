import { useMemo, useState } from "react";
import type {
  BifoldParams,
  CardHolderParams,
  CardOrientation,
  Currency,
  SlotConstruction,
} from "@odk/patterns";
import {
  BANKNOTES,
  BIFOLD_DEFAULTS,
  CATEGORIES,
  DEFAULT_PARAMS,
  buildInstructions,
  categoryHasAvailable,
  familiesByCategory,
  generateBifold,
  generateCardHolder,
  stitchSummaryFor,
  STATUS_LABEL,
} from "./engine.js";

type FamilyId = "card-holder-fold" | "bifold";
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
  const [family, setFamily] = useState<FamilyId>("card-holder-fold");
  const [params, setParams] = useState<CardHolderParams>(DEFAULT_PARAMS);
  const [bifold, setBifold] = useState<BifoldParams>(BIFOLD_DEFAULTS);
  const [print, setPrint] = useState<PrintState>(INITIAL_PRINT);

  const isBifold = family === "bifold";
  // Talimatlar ve PDF her iki aile için de bu dar bağlamı kullanıyor.
  const ctx = isBifold ? bifold : params;

  const set = <K extends keyof CardHolderParams>(
    key: K,
    value: CardHolderParams[K],
  ) => setParams((p) => ({ ...p, [key]: value }));

  const setB = <K extends keyof BifoldParams>(key: K, value: BifoldParams[K]) =>
    setBifold((p) => ({ ...p, [key]: value }));

  const result = useMemo(() => {
    try {
      return {
        ok: true as const,
        value: isBifold ? generateBifold(bifold) : generateCardHolder(params),
      };
    } catch (err) {
      return {
        ok: false as const,
        message: err instanceof Error ? err.message : String(err),
      };
    }
  }, [isBifold, params, bifold]);

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
                {familiesByCategory(c.id).map((f) => {
                  const usable = f.status === "hazir";
                  const active = usable && f.id === family;
                  return (
                    <li key={f.id}>
                      <button
                        type="button"
                        className="fam-item"
                        data-status={f.status}
                        data-active={active}
                        disabled={!usable}
                        aria-pressed={active}
                        onClick={() => {
                          if (usable) setFamily(f.id as FamilyId);
                        }}
                      >
                        <span>{f.name}</span>
                        <span className="fam-status">
                          {STATUS_LABEL[f.status]}
                        </span>
                      </button>
                    </li>
                  );
                })}
              </ul>
              {!categoryHasAvailable(c.id) && (
                <p className="hint">{c.description}</p>
              )}
            </div>
          ))}
        </div>

        {isBifold ? (
          <fieldset className="group" style={{ border: 0, margin: 0, padding: 0 }}>
            <legend>Bifold</legend>
            <Slider
              label="Panel başına yuva"
              value={bifold.cardSlotsPerSide}
              min={1}
              max={6}
              step={1}
              onChange={(v) => setB("cardSlotsPerSide", v)}
            />
            <Select
              label="Banknot"
              value={bifold.currency}
              options={Object.values(BANKNOTES).map((b) => ({
                value: b.currency,
                label: b.label + (b.verified ? "" : " ⚠"),
              }))}
              hint="Cüzdanın açık genişliğini en büyük kupür belirler."
              onChange={(v) => setB("currency", v as Currency)}
            />
            <Choice<SlotConstruction>
              label="Yapım biçimi"
              value={bifold.construction}
              options={[
                { value: "t-slot", label: "T-slot" },
                { value: "stacked", label: "Düz yığın" },
              ]}
              onChange={(v) => setB("construction", v)}
            />
            <Slider
              label="Kademe"
              value={bifold.reveal}
              min={5}
              max={22}
              step={0.5}
              unit="mm"
              onChange={(v) => setB("reveal", v)}
            />
            <Slider
              label="Dış kabuk"
              value={bifold.outerThickness}
              min={0.6}
              max={1.4}
              step={0.1}
              unit="mm"
              onChange={(v) => setB("outerThickness", v)}
            />
            <Slider
              label="İç kabuk"
              value={bifold.innerThickness}
              min={0.5}
              max={1.2}
              step={0.1}
              unit="mm"
              onChange={(v) => setB("innerThickness", v)}
            />
            <Slider
              label="Yuva derisi"
              value={bifold.slotThickness}
              min={0.4}
              max={1.0}
              step={0.1}
              unit="mm"
              onChange={(v) => setB("slotThickness", v)}
            />
            <Slider
              label="Dikiş payı"
              value={bifold.stitchMargin}
              min={2.5}
              max={5}
              step={0.5}
              unit="mm"
              onChange={(v) => setB("stitchMargin", v)}
            />
            <Slider
              label="Köşe yarıçapı"
              value={bifold.cornerRadius}
              min={0}
              max={12}
              step={0.5}
              unit="mm"
              onChange={(v) => setB("cornerRadius", v)}
            />
            <Select
              label="Pricking iron"
              value={bifold.pitch === undefined ? "auto" : String(bifold.pitch)}
              options={[
                { value: "3", label: "3.0 mm" },
                { value: "3.38", label: "3.38 mm" },
                { value: "3.85", label: "3.85 mm" },
                { value: "4", label: "4.0 mm" },
                { value: "auto", label: "Oto — en az delik" },
              ]}
              onChange={(v) =>
                setBifold((p) => {
                  if (v === "auto") {
                    const { pitch: _drop, ...rest } = p;
                    return rest;
                  }
                  return { ...p, pitch: Number(v) };
                })
              }
            />
            <Choice<string>
              label="Kalem payı"
              value={String(bifold.penAllowance)}
              options={[
                { value: "0", label: "0" },
                { value: "0.3", label: "0.3mm" },
                { value: "0.5", label: "0.5mm" },
              ]}
              onChange={(v) => setB("penAllowance", Number(v))}
            />
          </fieldset>
        ) : (
          <>
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
          </>
        )}

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
                    title: isBifold
                      ? `Bifold ${bifold.cardSlotsPerSide}+${bifold.cardSlotsPerSide} yuva`
                      : `Kartlık ${params.cardCount} yuva`,
                    params: ctx,
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
          <Result value={result.value} ctx={ctx} isBifold={isBifold} />
        )}
      </main>
    </div>
  );
}

function Result({
  value,
  ctx,
  isBifold,
}: {
  value: ReturnType<typeof generateCardHolder>;
  ctx: CardHolderParams | BifoldParams;
  isBifold: boolean;
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
          {isBifold
            ? `${(ctx as BifoldParams).cardSlotsPerSide}+${(ctx as BifoldParams).cardSlotsPerSide} yuva`
            : `${(ctx as CardHolderParams).cardCount} yuva`}{" "}
          · {ctx.construction === "t-slot" ? "T-slot" : "düz yığın"} · {s.pitch}mm
          adım · {s.totalHoles} delik
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
          {buildInstructions(value, ctx).map((step) => (
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
