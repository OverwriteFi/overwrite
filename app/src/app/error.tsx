"use client";

import { ErrorState } from "@/components/site/States";

export default function RootError({ error, reset }: { error: Error & { digest?: string }; reset: () => void }) {
  return (
    <div className="wrap pt-12 sm:pt-16">
      <ErrorState detail={error.message} onRetry={reset} />
    </div>
  );
}
