import { useMemo, useState } from "react";
import type {
  BifoldParams,
  GussetStyle,
  StrapStyle,
  ToteParams,
  CardHolderParams,
  CardOrientation,
  Currency,
  SlotConstruction,
  WalletStack,
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
  generateTote,
  stitchSummaryFor,
  STATUS_LABEL,
  TOTE_DEFAULTS,
  DEFAULT_RATES,
  DEFAULT_TIME_MODEL,
  costNotes,
  estimateCost,
  WALLET_STACK_DEFAULTS,
  MAX_PANEL_SLOTS,
  withSlotCount,
  compileToBifoldParams,
  generateFromStack,
  stackContributions,
  validateStack,
} from "./engine.js";
import type { CostOptions, CostRates } from "@odk/patterns";

type FamilyId = "card-holder-fold" | "bifold" | "tote";
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
  readonly allowRotation: boolean;
  readonly measured: string;
  readonly scaleFactor: number;
  readonly note: string;
  readonly noteOk: boolean;
  readonly busy: boolean;
}

const INITIAL_PRINT: PrintState = {
  printAllHoles: true,
  allowRotation: true,
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
  const [tote, setTote] = useState<ToteParams>(TOTE_DEFAULTS);
  const [print, setPrint] = useState<PrintState>(INITIAL_PRINT);
  const [rates, setRates] = useState<CostRates>(DEFAULT_RATES);
  const [speed, setSpeed] = useState(1);
  const [manualHours, setManualHours] = useState("");

  // "Kendi cüzdanını kur" modu: kullanıcı bir modül yığını (WalletStack)
  // kurar; yığın kanıtlanmış bifold çözücüsüne DERLENİR. Basit aile-seç
  // paneli yerinde kalır, bu onun yanındaki ikinci kapı.
  const [mode, setMode] = useState<"simple" | "builder">("simple");
  const [stack, setStack] = useState<WalletStack>(WALLET_STACK_DEFAULTS);
  const isBuilder = mode === "builder";

  const setStackSetting = <K extends keyof WalletStack["settings"]>(
    key: K,
    value: WalletStack["settings"][K],
  ) => setStack((s) => ({ ...s, settings: { ...s.settings, [key]: value } }));

  const builderParams = useMemo(() => compileToBifoldParams(stack), [stack]);
  const builderContrib = useMemo(() => stackContributions(stack), [stack]);
  const builderWarnings = useMemo(() => validateStack(stack), [stack]);

  const isBifold = family === "bifold";
  const isTote = family === "tote";
  // Talimatlar ve PDF üç aile için de bu dar bağlamı kullanıyor.
  const ctx = isBuilder
    ? builderParams
    : isTote
      ? { ...tote, kind: "canta" as const }
      : isBifold
        ? bifold
        : params;

  const set = <K extends keyof CardHolderParams>(
    key: K,
    value: CardHolderParams[K],
  ) => setParams((p) => ({ ...p, [key]: value }));

  const setB = <K extends keyof BifoldParams>(key: K, value: BifoldParams[K]) =>
    setBifold((p) => ({ ...p, [key]: value }));

  const setT = <K extends keyof ToteParams>(key: K, value: ToteParams[K]) =>
    setTote((p) => ({ ...p, [key]: value }));

  const parsedHours = Number(manualHours);
  const costOptions: CostOptions = {
    speedFactor: speed,
    ...(manualHours !== "" && Number.isFinite(parsedHours) && parsedHours > 0
      ? { overrideTotalHours: parsedHours }
      : {}),
  };

  const result = useMemo(() => {
    try {
      return {
        ok: true as const,
        value: isBuilder
          ? generateFromStack(stack)
          : isTote
            ? generateTote(tote)
            : isBifold
              ? generateBifold(bifold)
              : generateCardHolder(params),
      };
    } catch (err) {
      return {
        ok: false as const,
        message: err instanceof Error ? err.message : String(err),
      };
    }
  }, [isBuilder, stack, isBifold, isTote, params, bifold, tote]);

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
          <span className="group-title">Mod</span>
          <div className="segmented" role="group" aria-label="Mod">
            <button
              type="button"
              aria-pressed={!isBuilder}
              onClick={() => setMode("simple")}
            >
              Basit
            </button>
            <button
              type="button"
              aria-pressed={isBuilder}
              onClick={() => setMode("builder")}
            >
              Kendi cüzdanını kur
            </button>
          </div>
        </div>

        {!isBuilder && (
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
        )}

        {isBuilder ? (
          <fieldset className="group" style={{ border: 0, margin: 0, padding: 0 }}>
            <legend>Kendi cüzdanını kur</legend>
            <p className="hint">
              Modül ekleyip çıkararak cüzdanını kur. Yığın, kanıtlanmış bifold
              çözücüsüne derlenir — boş yığın = varsayılan bifold.
            </p>
            <Slider
              label="Kart yuvası (panel başına)"
              value={stack.slots.length}
              min={0}
              max={MAX_PANEL_SLOTS}
              step={1}
              onChange={(v) => setStack((s) => withSlotCount(s, v))}
              hint={`Her panelde ${stack.slots.length} yuva · iki panel simetrik.`}
            />
            <Select
              label="Banknot bölmesi"
              value={stack.spine.currency}
              options={[
                { value: "TRY", label: "Türk Lirası" },
                { value: "USD", label: "Dolar" },
                { value: "EUR", label: "Euro" },
                { value: "GBP", label: "Sterlin" },
              ]}
              onChange={(v) =>
                setStack((s) => ({
                  ...s,
                  spine: { kind: "billPocket", currency: v as Currency },
                }))
              }
            />
            <Choice
              label="Yuva yapımı"
              value={stack.settings.construction}
              options={[
                { value: "t-slot", label: "T-slot" },
                { value: "stacked", label: "Düz" },
              ]}
              onChange={(v) =>
                setStackSetting("construction", v as SlotConstruction)
              }
              hint="T-slot kenarı sabit tutar; düz yuvalar kenarda birikir."
            />
            <Slider
              label="Kademe (reveal)"
              value={stack.settings.reveal}
              min={5}
              max={20}
              step={1}
              unit="mm"
              onChange={(v) => setStackSetting("reveal", v)}
            />
            <Slider
              label="Yuva derisi"
              value={stack.settings.slotThickness}
              min={0.4}
              max={1.2}
              step={0.1}
              unit="mm"
              onChange={(v) => setStackSetting("slotThickness", v)}
            />
            <Slider
              label="Dış kabuk"
              value={stack.settings.outerThickness}
              min={0.6}
              max={2}
              step={0.1}
              unit="mm"
              onChange={(v) => setStackSetting("outerThickness", v)}
            />
            <Slider
              label="İç kabuk"
              value={stack.settings.innerThickness}
              min={0.6}
              max={1.6}
              step={0.1}
              unit="mm"
              onChange={(v) => setStackSetting("innerThickness", v)}
            />
            <Slider
              label="Dikiş payı"
              value={stack.settings.stitchMargin}
              min={2.5}
              max={5}
              step={0.5}
              unit="mm"
              onChange={(v) => setStackSetting("stitchMargin", v)}
            />

            <span className="group-title">Yığın dökümü (yüklü · yükseklik)</span>
            <table className="readout">
              <tbody>
                {builderContrib.modules.map((m, i) => (
                  <tr key={i}>
                    <td>{m.label}</td>
                    <td style={{ textAlign: "right" }}>
                      {m.loadedThickness.toFixed(1)}mm
                    </td>
                    <td style={{ textAlign: "right" }}>
                      {m.height.toFixed(0)}mm
                    </td>
                  </tr>
                ))}
                <tr>
                  <td>boş / yüklü</td>
                  <td style={{ textAlign: "right" }} colSpan={2}>
                    {builderContrib.closedThickness.toFixed(1)} /{" "}
                    {builderContrib.loadedThickness.toFixed(1)}mm
                  </td>
                </tr>
                <tr>
                  <td>bölme genişliği</td>
                  <td style={{ textAlign: "right" }} colSpan={2}>
                    {builderContrib.compartmentWidth.toFixed(1)}mm
                  </td>
                </tr>
                <tr>
                  <td>asgari yükseklik</td>
                  <td style={{ textAlign: "right" }} colSpan={2}>
                    {builderContrib.minWalletHeight.toFixed(1)}mm
                  </td>
                </tr>
              </tbody>
            </table>

            {builderWarnings.length > 0 && (
              <ul className="diagnostics">
                {builderWarnings.map((d, i) => (
                  <li
                    key={i}
                    className="diagnostic"
                    data-severity={d.severity}
                  >
                    <code>{d.code}</code>
                    <span>{d.message}</span>
                  </li>
                ))}
              </ul>
            )}
          </fieldset>
        ) : isTote ? (
          <fieldset className="group" style={{ border: 0, margin: 0, padding: 0 }}>
            <legend>Çanta</legend>
            <Slider
              label="Genişlik"
              value={tote.width}
              min={140}
              max={340}
              step={5}
              unit="mm"
              onChange={(v) => setT("width", v)}
            />
            <Slider
              label="Yükseklik"
              value={tote.height}
              min={120}
              max={340}
              step={5}
              unit="mm"
              onChange={(v) => setT("height", v)}
            />
            <Slider
              label="Derinlik (körük)"
              value={tote.depth}
              min={30}
              max={160}
              step={5}
              unit="mm"
              onChange={(v) => setT("depth", v)}
            />
            <Slider
              label="Alt köşe yarıçapı"
              value={tote.cornerRadius}
              min={10}
              max={90}
              step={5}
              unit="mm"
              hint="Derinliğin yarısından küçük olursa körük köşede buruşur."
              onChange={(v) => setT("cornerRadius", v)}
            />
            <Choice<GussetStyle>
              label="Körük"
              value={tote.gusset}
              options={[
                { value: "uc-parca", label: "Üç parça" },
                { value: "tek-parca", label: "Tek parça" },
              ]}
              hint="Üç parça A4'e sığar ama iki ek dikiş getirir. Tek parça dikişsiz ama sayfalara bölünür."
              onChange={(v) => setT("gusset", v)}
            />
            <Select
              label="Askı"
              value={tote.strap}
              options={[
                { value: "yok", label: "Askısız" },
                { value: "el", label: "El sapı (2 adet)" },
                { value: "omuz", label: "Omuz askısı" },
                { value: "capraz", label: "Çapraz askı" },
              ]}
              onChange={(v) => setT("strap", v as StrapStyle)}
            />
            {tote.strap !== "yok" && (
              <Slider
                label="Askı drop"
                value={(tote.strapDrop ?? 550) / 10}
                min={20}
                max={70}
                step={1}
                unit="cm"
                hint="Askının tepesinden çantanın üst kenarına dikey mesafe."
                onChange={(v) => setT("strapDrop", v * 10)}
              />
            )}
            <Slider
              label="Panel derisi"
              value={tote.panelThickness}
              min={1.0}
              max={3.0}
              step={0.1}
              unit="mm"
              hint="Çanta yapısal yük taşıyor: 1.6–2.4mm öneriliyor."
              onChange={(v) => setT("panelThickness", v)}
            />
            <Slider
              label="Körük derisi"
              value={tote.gussetThickness}
              min={1.0}
              max={2.6}
              step={0.1}
              unit="mm"
              onChange={(v) => setT("gussetThickness", v)}
            />
            <Slider
              label="Askı derisi"
              value={tote.strapThickness}
              min={1.4}
              max={3.6}
              step={0.1}
              unit="mm"
              onChange={(v) => setT("strapThickness", v)}
            />
            <Slider
              label="Dikiş payı"
              value={tote.stitchMargin}
              min={3}
              max={6}
              step={0.5}
              unit="mm"
              onChange={(v) => setT("stitchMargin", v)}
            />
            <Select
              label="Pricking iron"
              value={tote.pitch === undefined ? "auto" : String(tote.pitch)}
              options={[
                { value: "3.85", label: "3.85 mm" },
                { value: "4", label: "4.0 mm" },
                { value: "5", label: "5.0 mm" },
                { value: "auto", label: "Oto — en az delik" },
              ]}
              onChange={(v) =>
                setTote((p) => {
                  if (v === "auto") {
                    const { pitch: _drop, ...rest } = p;
                    return rest;
                  }
                  return { ...p, pitch: Number(v) };
                })
              }
            />
          </fieldset>
        ) : isBifold ? (
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
          <legend>Maliyet</legend>
          <p className="hint">
            Alan ve süre kalıptan hesaplanıyor. Fiyatları sen giriyorsun —
            deri ve işçilik ücretleri tabakhaneye, ülkeye ve aya göre
            değişiyor, motor bunları bilemez.
          </p>
          {(
            [
              ["leatherPerDm2", "Deri", "/dm²", 0, 500, 5],
              ["labourPerHour", "İşçilik", "/saat", 0, 2000, 25],
              ["consumablesPerHour", "Sarf", "/saat", 0, 300, 5],
              ["hardware", "Donanım", "toplam", 0, 2000, 25],
            ] as const
          ).map(([key, label, unit, min, max, step]) => (
            <Slider
              key={key}
              label={`${label} (${unit})`}
              value={rates[key]}
              min={min}
              max={max}
              step={step}
              onChange={(v) => setRates((p) => ({ ...p, [key]: v }))}
            />
          ))}
          <Slider
            label="Hız katsayısı"
            value={speed}
            min={0.3}
            max={1.6}
            step={0.05}
            hint="1 = modelin tahmini. 0.6 = tahminden %40 hızlı çalışıyorum."
            onChange={setSpeed}
          />
          <div className="field">
            <div className="field-head">
              <label htmlFor="mh">Toplam süre (elle)</label>
              <span className="field-value">saat</span>
            </div>
            <div className="calibrate">
              <input
                id="mh"
                type="number"
                step="0.25"
                min="0"
                placeholder="boş = hesapla"
                value={manualHours}
                onChange={(ev) => setManualHours(ev.target.value)}
              />
              <button type="button" onClick={() => setManualHours("")}>
                Temizle
              </button>
            </div>
            <p className="hint">
              Kendi süreni ölçtüysen buraya gir; model tahmini devre dışı
              kalır. Ölçülen süre her zaman tahminden iyidir.
            </p>
          </div>
          <Slider
            label="Genel gider"
            value={Math.round(rates.overheadRate * 100)}
            min={0}
            max={60}
            step={5}
            unit="%"
            onChange={(v) => setRates((p) => ({ ...p, overheadRate: v / 100 }))}
          />
          <Slider
            label="Kâr marjı"
            value={Math.round(rates.marginRate * 100)}
            min={0}
            max={150}
            step={5}
            unit="%"
            onChange={(v) => setRates((p) => ({ ...p, marginRate: v / 100 }))}
          />
          <Slider
            label="KDV"
            value={Math.round(rates.vatRate * 100)}
            min={0}
            max={30}
            step={1}
            unit="%"
            onChange={(v) => setRates((p) => ({ ...p, vatRate: v / 100 }))}
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

          <Choice<string>
            label="Sayfaya sığdırma"
            value={print.allowRotation ? "rotate" : "tile"}
            options={[
              { value: "rotate", label: "Döndür" },
              { value: "tile", label: "Böl" },
            ]}
            hint="Döndür: parça 90° çevrilip tek sayfaya sığar, hizalama gerekmez. Böl: parça sayfalara bölünür, kesip yapıştırman gerekir."
            onChange={(v) =>
              setPrint((p) => ({ ...p, allowRotation: v === "rotate" }))
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
                    allowRotation: print.allowRotation,
                    scaleFactor: print.scaleFactor,
                    title: isBuilder
                      ? `Cüzdan ${stack.slots.length}+${stack.slots.length} yuva`
                      : isTote
                        ? `Çanta ${tote.width}x${tote.height}x${tote.depth}`
                        : isBifold
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
          <Result
            value={result.value}
            ctx={ctx}
            family={isBuilder ? "bifold" : family}
            rates={rates}
            costOptions={costOptions}
          />
        )}
      </main>
    </div>
  );
}

function Result({
  value,
  ctx,
  family,
  rates,
  costOptions,
}: {
  value: ReturnType<typeof generateCardHolder>;
  ctx: CardHolderParams | BifoldParams | (ToteParams & { kind: "canta" });
  family: FamilyId;
  rates: CostRates;
  costOptions: CostOptions;
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
          {family === "tote"
            ? `${(ctx as ToteParams).width}×${(ctx as ToteParams).height}×${(ctx as ToteParams).depth}mm`
            : family === "bifold"
              ? `${(ctx as BifoldParams).cardSlotsPerSide}+${(ctx as BifoldParams).cardSlotsPerSide} yuva · ${(ctx as BifoldParams).construction === "t-slot" ? "T-slot" : "düz yığın"}`
              : `${(ctx as CardHolderParams).cardCount} yuva · ${(ctx as CardHolderParams).construction === "t-slot" ? "T-slot" : "düz yığın"}`}{" "}
          · {s.pitch}mm adım · {s.totalHoles} delik
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

      <CostPanel value={value} rates={rates} costOptions={costOptions} />

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
            {(s.metrics ?? []).map((mt) => (
              <tr key={mt.label}>
                <th scope="row">{mt.label}</th>
                <td className="num">{mt.value}</td>
              </tr>
            ))}
            <tr>
              <th scope="row">dikiş</th>
              <td className="num">
                {s.pitch}mm · {s.totalHoles} delik
              </td>
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


function CostPanel({
  value,
  rates,
  costOptions,
}: {
  value: ReturnType<typeof generateCardHolder>;
  rates: CostRates;
  costOptions: CostOptions;
}) {
  const c = estimateCost(value, rates, costOptions);
  const notes = costNotes(c, rates);
  const money = (n: number) => `${Math.round(n).toLocaleString("tr-TR")} ${c.currency}`;
  const hours = (n: number) => `${n.toFixed(2)} sa`;

  return (
    <section className="cost">
      <h3>Maliyet ve önerilen fiyat</h3>
      <div className="cost-headline">
        <span className="cost-price">{money(c.priceIncVat)}</span>
        <span className="cost-sub">
          KDV dahil · KDV hariç {money(c.priceExVat)} · maliyet {money(c.totalCost)}
        </span>
      </div>

      <div className="columns">
        <table className="readout">
          <caption>Malzeme ve süre</caption>
          <tbody>
            <tr>
              <th scope="row">net deri</th>
              <td className="num">{c.netAreaDm2.toFixed(2)} dm²</td>
            </tr>
            <tr>
              <th scope="row">fire dahil</th>
              <td className="num">{c.grossAreaDm2.toFixed(2)} dm²</td>
            </tr>
            <tr>
              <th scope="row">kesim</th>
              <td className="num">{hours(c.cuttingHours)}</td>
            </tr>
            <tr>
              <th scope="row">delme</th>
              <td className="num">{hours(c.punchingHours)}</td>
            </tr>
            <tr>
              <th scope="row">dikiş</th>
              <td className="num">{hours(c.stitchingHours)}</td>
            </tr>
            <tr>
              <th scope="row">kenar</th>
              <td className="num">{hours(c.edgeHours)}</td>
            </tr>
            <tr>
              <th scope="row">montaj</th>
              <td className="num">{hours(c.assemblyHours)}</td>
            </tr>
            <tr>
              <th scope="row">
                toplam{c.hoursOverridden ? " (elle)" : ""}
              </th>
              <td className="num">{hours(c.totalHours)}</td>
            </tr>
            {c.hoursOverridden && (
              <tr>
                <th scope="row">model tahmini</th>
                <td className="num">{hours(c.modelHours)}</td>
              </tr>
            )}
            <tr>
              <th scope="row">saat başı</th>
              <td className="num">
                {money(
                  c.totalHours > 0
                    ? (c.labourCost + c.consumablesCost) / c.totalHours
                    : 0,
                )}
              </td>
            </tr>
          </tbody>
        </table>

        <table className="readout">
          <caption>Fiyat zinciri</caption>
          <tbody>
            <tr>
              <th scope="row">deri</th>
              <td className="num">{money(c.leatherCost)}</td>
            </tr>
            <tr>
              <th scope="row">işçilik</th>
              <td className="num">{money(c.labourCost)}</td>
            </tr>
            <tr>
              <th scope="row">sarf</th>
              <td className="num">{money(c.consumablesCost)}</td>
            </tr>
            {c.hardwareCost > 0 && (
              <tr>
                <th scope="row">donanım</th>
                <td className="num">{money(c.hardwareCost)}</td>
              </tr>
            )}
            <tr>
              <th scope="row">genel gider</th>
              <td className="num">{money(c.overhead)}</td>
            </tr>
            <tr>
              <th scope="row">maliyet</th>
              <td className="num">{money(c.totalCost)}</td>
            </tr>
            <tr>
              <th scope="row">kâr</th>
              <td className="num">{money(c.margin)}</td>
            </tr>
            <tr>
              <th scope="row">KDV</th>
              <td className="num">{money(c.vat)}</td>
            </tr>
          </tbody>
        </table>
      </div>

      <ul className="diagnostics">
        {notes.map((n, i) => (
          <li key={i} className="diagnostic" data-severity={n.severity}>
            <code>{n.severity === "warning" ? "DİKKAT" : "NOT"}</code>
            <span>{n.message}</span>
          </li>
        ))}
      </ul>
    </section>
  );
}
