import type { Polyline, Vec } from "@odk/geometry";
import type { PatternPiece } from "@odk/patterns";

/**
 * Parça çizimi.
 *
 * Ölçek: SVG viewBox milimetre cinsinden. Böylece hiçbir yerde piksel
 * dönüşümü yapılmıyor ve çizim doğrudan 1:1 basılabilir hâle geliyor
 * (Faz 2'de PDF katmanı aynı koordinatları kullanacak).
 *
 * Y ekseni: motor matematiksel yön kullanıyor (y yukarı), SVG ters.
 * Çevirme burada, tek yerde yapılıyor.
 */

const MARGIN = 8; // mm, çizim etrafındaki boşluk

interface Props {
  readonly piece: PatternPiece;
  readonly pxPerMm: number;
}

function toPathData(poly: Polyline, height: number): string {
  if (poly.length === 0) return "";
  const pts = poly.map((p) => `${p.x.toFixed(3)},${(height - p.y).toFixed(3)}`);
  return `M ${pts.join(" L ")} Z`;
}

export function PieceView({ piece, pxPerMm }: Props) {
  const w = piece.width + MARGIN * 2;
  const h = piece.height + MARGIN * 2;

  // Kesim hattı orijinden başlamıyor olabilir; sol-alt köşeye taşı.
  const minX = Math.min(...piece.cutLine.map((p) => p.x));
  const minY = Math.min(...piece.cutLine.map((p) => p.y));
  const shift = (p: Vec): Vec => ({
    x: p.x - minX + MARGIN,
    y: p.y - minY + MARGIN,
  });

  const cut = piece.cutLine.map(shift);
  const stitch = piece.stitchLine?.map(shift);
  const holes = piece.stitchPlan?.holes.map((hole) => shift(hole.position)) ?? [];

  return (
    <svg
      className="piece-canvas"
      viewBox={`0 0 ${w} ${h}`}
      width={w * pxPerMm}
      height={h * pxPerMm}
      role="img"
      aria-label={`${piece.name} kalıbı, ${piece.width.toFixed(1)} çarpı ${piece.height.toFixed(1)} milimetre`}
    >
      <defs>
        {/* Kesim matı ızgarası: 10mm ince, 50mm kalın. */}
        <pattern id={`grid-${piece.id}`} width="10" height="10" patternUnits="userSpaceOnUse">
          <path d="M 10 0 L 0 0 0 10" fill="none" stroke="var(--mat-grid)" strokeWidth="0.15" />
        </pattern>
        <pattern id={`grid50-${piece.id}`} width="50" height="50" patternUnits="userSpaceOnUse">
          <rect width="50" height="50" fill={`url(#grid-${piece.id})`} />
          <path d="M 50 0 L 0 0 0 50" fill="none" stroke="var(--mat-grid-major)" strokeWidth="0.3" />
        </pattern>
      </defs>

      <rect width={w} height={h} fill={`url(#grid50-${piece.id})`} />

      {/* Kesim hattı: ince, sürekli. "Çizginin dışından kes" kuralı için
          mümkün olduğunca ince tutuluyor. */}
      <path
        d={toPathData(cut, h)}
        fill="rgba(242,239,230,0.05)"
        stroke="var(--bone)"
        strokeWidth="0.35"
        strokeLinejoin="round"
      />

      {/* Dikiş hattı: kesikli. */}
      {stitch !== undefined && (
        <path
          d={toPathData(stitch, h)}
          fill="none"
          stroke="var(--brass-dim)"
          strokeWidth="0.3"
          strokeDasharray="2 1.6"
        />
      )}

      {/* Kat çizgileri: noktalı. */}
      {piece.foldLines.map((f, i) => {
        const a = shift(f.from);
        const b = shift(f.to);
        return (
          <line
            key={i}
            x1={a.x}
            y1={h - a.y}
            x2={b.x}
            y2={h - b.y}
            stroke="var(--chalk)"
            strokeWidth="0.3"
            strokeDasharray="0.8 1.6"
          />
        );
      })}

      {/* Dikiş delikleri. */}
      {holes.map((p, i) => (
        <circle key={i} cx={p.x} cy={h - p.y} r="0.55" fill="var(--brass)" />
      ))}
    </svg>
  );
}
