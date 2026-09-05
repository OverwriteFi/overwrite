/** The landing's payoff chart: holding vs the vault over one week of price changes. Same geometry as `drawChart`. */
export function PayoffChart({ dist, prem }: { dist: number; prem: number }) {
  const W = 560,
    H = 250,
    L = 44,
    R = 14,
    Tp = 16,
    B = 30;
  const xmin = -15,
    xmax = 20,
    ymin = -15,
    ymax = 20;
  const X = (v: number) => L + ((v - xmin) / (xmax - xmin)) * (W - L - R);
  const Y = (v: number) => Tp + ((ymax - v) / (ymax - ymin)) * (H - Tp - B);
  let hold = "";
  let ow = "";
  for (let v = xmin; v <= xmax; v += 0.5) {
    const y1 = v;
    const y2 = Math.min(v, dist) + prem * 100;
    hold += (v === xmin ? "M" : "L") + X(v).toFixed(1) + "," + Y(y1).toFixed(1) + " ";
    ow += (v === xmin ? "M" : "L") + X(v).toFixed(1) + "," + Y(y2).toFixed(1) + " ";
  }
  const ticks = [-15, -10, -5, 0, 5, 10, 15, 20];
  const lbl = (t: number) => (t > 0 ? "+" : "") + t + "%";
  return (
    <svg viewBox="0 0 560 250" id="pay">
      <line className="axis" x1={L} y1={Tp} x2={L} y2={H - B} />
      <line className="zero" x1={L} y1={Y(0)} x2={W - R} y2={Y(0)} />
      {ticks.map((t) => (
        <g key={t}>
          <text x={X(t)} y={H - 10} textAnchor="middle">
            {lbl(t)}
          </text>
          <text x={L - 6} y={Y(t) + 4} textAnchor="end">
            {lbl(t)}
          </text>
        </g>
      ))}
      <line className="kline" x1={X(dist)} y1={Tp} x2={X(dist)} y2={H - B} />
      <path className="hold" d={hold} />
      <path className="ow" d={ow} />
      <text x={W - R} y={Y(xmax) + 14} textAnchor="end">
        Holding
      </text>
      <text x={W - R} y={Y(dist + prem * 100) - 8} textAnchor="end" style={{ fill: "#2A3BFF", fontWeight: 700 }}>
        Vault
      </text>
      <text x={W - R} y={H - B - 6} textAnchor="end">
        Token price change over the week
      </text>
    </svg>
  );
}
