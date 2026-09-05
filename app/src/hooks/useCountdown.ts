"use client";

import { useEffect, useState } from "react";

/**
 * Seconds until `targetUnix`, ticking once a second, anchored to chain time rather than the browser
 * clock: the server tells us what the chain's clock read when it was fetched and we carry that offset.
 * The anvil fork warps time, so this is the only way the countdown stays honest there.
 */
export function useChainClock(chainNow: string, fetchedAt: string) {
  const [now, setNow] = useState(() => Number(chainNow));
  useEffect(() => {
    const fetchedMs = Date.parse(fetchedAt) || Date.now();
    const offset = Number(chainNow) - Math.floor(fetchedMs / 1000);
    const tick = () => setNow(Math.floor(Date.now() / 1000) + offset);
    tick();
    const t = setInterval(tick, 1000);
    return () => clearInterval(t);
  }, [chainNow, fetchedAt]);
  return now;
}

export function useCountdown(targetUnix: string | number | bigint, chainNow: string, fetchedAt: string) {
  const now = useChainClock(chainNow, fetchedAt);
  const target = Number(targetUnix);
  return { now, remaining: target > 0 ? target - now : 0, passed: target > 0 && now >= target };
}
