"use client";

import { ErrorState } from "@/components/site/States";

export default function VaultError({ error, reset }: { error: Error & { digest?: string }; reset: () => void }) {
  return (
    <div className="wrap pt-10 sm:pt-14">
      <ErrorState detail={error.message} onRetry={reset} />
    </div>
  );
}
