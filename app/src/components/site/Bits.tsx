import type { ReactNode } from "react";

/** Small ruled primitives. No cards, no shadows. */

export function Section({
  title,
  sub,
  children,
  id,
  className = "",
}: {
  title?: ReactNode;
  sub?: ReactNode;
  children: ReactNode;
  id?: string;
  className?: string;
}) {
  return (
    <section id={id} className={`mt-16 ${className}`}>
      {title ? <h2 className="h2">{title}</h2> : null}
      {sub ? <p className="sub">{sub}</p> : null}
      <div className={title || sub ? "mt-8" : ""}>{children}</div>
    </section>
  );
}

export function Stat({
  label,
  value,
  tag,
  ink = false,
  sub,
}: {
  label: string;
  value: ReactNode;
  tag?: ReactNode;
  ink?: boolean;
  sub?: ReactNode;
}) {
  return (
    <div className="border-t-[1.5px] border-ink pt-3">
      <span className="k">{label}</span>
      <div className={`stat-v ${ink ? "ink" : ""}`}>
        {value}
        {tag ? <Tag>{tag}</Tag> : null}
      </div>
      {sub ? <p className="note mt-1">{sub}</p> : null}
    </div>
  );
}

export function Tag({ children, blue = false }: { children: ReactNode; blue?: boolean }) {
  return <span className={`tag ${blue ? "tag-blue" : ""}`}>{children}</span>;
}

export function CapMeter({ fraction }: { fraction: number | null }) {
  if (fraction === null) return <span className="text-gray">—</span>;
  const pct = Math.max(0, Math.min(100, Math.round(fraction * 100)));
  return (
    <span className="inline-flex items-center gap-[10px] whitespace-nowrap">
      <span className="cap-bar" aria-hidden>
        <i style={{ width: `${pct}%` }} />
      </span>
      {pct}% of cap
    </span>
  );
}

export function Rows({ children }: { children: ReactNode }) {
  return <div className="rows">{children}</div>;
}

export function Row({ label, children, note }: { label: ReactNode; children: ReactNode; note?: ReactNode }) {
  return (
    <div>
      <div>
        <span>{label}</span>
        {note ? <span className="note block">{note}</span> : null}
      </div>
      <span className="v">{children}</span>
    </div>
  );
}
