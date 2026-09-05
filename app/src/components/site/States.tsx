import Link from "next/link";
import type { ReactNode } from "react";

/** Loading, empty and error states. Each one tells the reader what to do next. */

export function Loading({ label = "Reading the chain…" }: { label?: string }) {
  return (
    <div role="status" aria-live="polite" className="py-10">
      <p className="text-gray">{label}</p>
      <div className="mt-6 space-y-3" aria-hidden>
        <div className="h-[1.5px] bg-ink" />
        <div className="h-4 w-2/3 bg-bg-2 rounded-sm" />
        <div className="h-px bg-rule" />
        <div className="h-4 w-1/2 bg-bg-2 rounded-sm" />
        <div className="h-px bg-rule" />
        <div className="h-4 w-3/5 bg-bg-2 rounded-sm" />
      </div>
    </div>
  );
}

export function Empty({
  title,
  children,
  action,
}: {
  title: string;
  children?: ReactNode;
  action?: ReactNode;
}) {
  return (
    <div className="border-t-[1.5px] border-ink pt-5 max-w-[60ch]">
      <h3 className="h3">{title}</h3>
      {children ? <p className="mt-2 text-gray">{children}</p> : null}
      {action ? <div className="mt-4">{action}</div> : null}
    </div>
  );
}

export function ErrorState({
  title = "The chain did not answer.",
  detail,
  onRetry,
  retryHref,
}: {
  title?: string;
  detail?: string;
  onRetry?: () => void;
  retryHref?: string;
}) {
  return (
    <div role="alert" className="border-t-[1.5px] border-ink pt-5 max-w-[64ch]">
      <h3 className="h3">{title}</h3>
      <p className="mt-2 text-gray">
        Check that the RPC in <code className="text-ink">NEXT_PUBLIC_RPC_URL</code> reaches Robinhood
        Chain (chain id {process.env.NEXT_PUBLIC_CHAIN_ID ?? "46630"}), then try again. If you are
        running the anvil fork, make sure it is still up.
      </p>
      {detail ? <p className="note mt-2 break-words">{detail}</p> : null}
      <div className="mt-4 flex gap-3">
        {onRetry ? (
          <button type="button" className="btn btn-plain btn-sm" onClick={onRetry}>
            Try again
          </button>
        ) : null}
        {retryHref ? (
          <Link href={retryHref} className="btn btn-plain btn-sm">
            Try again
          </Link>
        ) : null}
      </div>
    </div>
  );
}
