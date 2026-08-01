import { useRef, useState } from "react";
import type { PointerEvent as ReactPointerEvent } from "react";
import type { NormPoint } from "@odk/patterns";
import { DEFAULT_CUSTOM_MOUTH, validateCustomMouth } from "./engine.js";

/**
 * AĞIZ PROFİLİ EDİTÖRÜ
 *
 * Kullanıcı, kart yuvasının ağzını soldan sağa bir profil olarak çizer.
 * Uç noktalar köşelere KİLİTLİ (u=0 ve u=1, v=0); yalnızca ara noktalar
 * sürüklenir ve her ara noktanın u'su komşuları arasında kalır. Bu iki
 * kısıt, profilin ASLA kendini kesmemesini garanti eder — motor her zaman
 * geçerli bir parça alır. (Doğrulama motorla aynı: validateCustomMouth.)
 *
 * Çizim NORMALİZE (u,v ∈ [0,1]) saklanır; gerçek mm'ye çevirme motorda,
 * o anki yuva kutusuna göre yapılır. Böylece kullanıcı ölçüleri
 * değiştirdiğinde profil bozulmaz.
 */

const W = 240;
const H = 90;

function clamp(x: number, a: number, b: number): number {
  return Math.max(a, Math.min(b, x));
}

export function MouthEditor({
  value,
  onChange,
}: {
  value: readonly NormPoint[];
  onChange: (pts: NormPoint[]) => void;
}) {
  const svgRef = useRef<SVGSVGElement>(null);
  const [drag, setDrag] = useState<number | null>(null);

  const pts = value.length >= 2 ? value : DEFAULT_CUSTOM_MOUTH;
  const valid = validateCustomMouth(pts);

  const toNorm = (e: ReactPointerEvent): NormPoint | null => {
    const svg = svgRef.current;
    if (svg === null) return null;
    const r = svg.getBoundingClientRect();
    return {
      u: clamp((e.clientX - r.left) / r.width, 0, 1),
      v: clamp((e.clientY - r.top) / r.height, 0, 1),
    };
  };

  const onMove = (e: ReactPointerEvent<SVGSVGElement>) => {
    if (drag === null || drag === 0 || drag === pts.length - 1) return;
    const n = toNorm(e);
    if (n === null) return;
    const lo = (pts[drag - 1] as NormPoint).u + 0.02;
    const hi = (pts[drag + 1] as NormPoint).u - 0.02;
    const u = clamp(n.u, lo, hi);
    onChange(pts.map((p, i) => (i === drag ? { u, v: n.v } : p)));
  };

  const addPoint = () => {
    let gi = 0;
    let gap = -1;
    for (let i = 0; i < pts.length - 1; i++) {
      const g = (pts[i + 1] as NormPoint).u - (pts[i] as NormPoint).u;
      if (g > gap) {
        gap = g;
        gi = i;
      }
    }
    const a = pts[gi] as NormPoint;
    const b = pts[gi + 1] as NormPoint;
    const mid: NormPoint = {
      u: (a.u + b.u) / 2,
      v: clamp((a.v + b.v) / 2 + 0.1, 0, 1),
    };
    onChange([...pts.slice(0, gi + 1), mid, ...pts.slice(gi + 1)]);
  };

  const removePoint = () => {
    if (pts.length <= 2) return;
    const mid = Math.floor(pts.length / 2);
    onChange(pts.filter((_, i) => i !== mid));
  };

  const reset = () => onChange([...DEFAULT_CUSTOM_MOUTH]);

  const profilePx = pts.map((p) => `${p.u * W},${p.v * H}`).join(" ");
  const leather = `${profilePx} ${W},${H} 0,${H}`;

  return (
    <div className="field">
      <div className="field-head">
        <label>Ağız profili — çiz</label>
      </div>
      <svg
        ref={svgRef}
        viewBox={`0 0 ${W} ${H}`}
        style={{
          width: "100%",
          height: "auto",
          touchAction: "none",
          border: "1px solid var(--panel-edge)",
          background: "var(--mat-deep)",
          borderRadius: 2,
          display: "block",
        }}
        onPointerMove={onMove}
        onPointerUp={() => setDrag(null)}
        onPointerLeave={() => setDrag(null)}
      >
        <polygon points={leather} fill="var(--mat-grid)" />
        <polyline
          points={profilePx}
          fill="none"
          stroke="var(--brass)"
          strokeWidth={2}
        />
        {pts.map((p, i) => {
          const locked = i === 0 || i === pts.length - 1;
          return (
            <circle
              key={i}
              cx={p.u * W}
              cy={p.v * H}
              r={locked ? 3.5 : 5}
              fill={locked ? "var(--bone-faint)" : "var(--brass)"}
              stroke="var(--bone)"
              strokeWidth={1}
              style={{ cursor: locked ? "default" : "grab" }}
              onPointerDown={(e: ReactPointerEvent<SVGCircleElement>) => {
                if (locked) return;
                e.currentTarget.setPointerCapture(e.pointerId);
                setDrag(i);
              }}
            />
          );
        })}
      </svg>
      <div
        className="segmented"
        role="group"
        aria-label="Ağız düzenle"
        style={{ marginTop: 6 }}
      >
        <button type="button" onClick={addPoint}>
          + nokta
        </button>
        <button type="button" onClick={removePoint} disabled={pts.length <= 2}>
          − nokta
        </button>
        <button type="button" onClick={reset}>
          sıfırla
        </button>
      </div>
      <p className="hint" data-severity={valid.ok ? undefined : "error"}>
        {valid.ok
          ? "Ara noktaları sürükle. Uçlar köşelere sabit; profil kendini kesemez."
          : valid.message}
      </p>
    </div>
  );
}
