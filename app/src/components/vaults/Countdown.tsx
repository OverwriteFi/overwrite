"use client";

import { useCountdown } from "@/hooks/useCountdown";
import { fmtCountdown, fmtDateUtc } from "@/lib/format";

export function Countdown({
  target,
  chainNow,
  fetchedAt,
  label,
  passedLabel = "Due now",
}: {
  target: string;
  chainNow: string;
  fetchedAt: string;
  label: string;
  passedLabel?: string;
}) {
  const { remaining, passed } = useCountdown(target, chainNow, fetchedAt);
  if (target === "0") {
    return (
      <div className="border-t-[1.5px] border-ink pt-3">
        <span className="k">{label}</span>
        <div className="stat-v ink">—</div>
      </div>
    );
  }
  return (
    <div className="border-t-[1.5px] border-ink pt-3">
      <span className="k">{label}</span>
      <div className="stat-v" aria-live="off">
        {passed ? passedLabel : fmtCountdown(remaining)}
      </div>
      <p className="note mt-1">{fmtDateUtc(target)}</p>
    </div>
  );
}
