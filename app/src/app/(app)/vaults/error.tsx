"use client";

import { ErrorState } from "@/components/site/States";

export default function VaultsError({ error, reset }: { error: Error & { digest?: string }; reset: () => void }) {
  return (
    <div className="wrap pt-12 sm:pt-16">
      <h1 className="h1">Make your Stock Tokens pay you every week.</h1>
      <div className="mt-10">
        <ErrorState detail={error.message} onRetry={reset} />
      </div>
    </div>
  );
}
