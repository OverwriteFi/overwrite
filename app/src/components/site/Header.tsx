import Link from "next/link";
import { WalletButton } from "@/components/wallet/WalletButton";
import { NavLinks } from "./NavLinks";

const stakeEnabled = process.env.NEXT_PUBLIC_STAKE_ENABLED === "true";

export function Header() {
  return (
    <header className="wrap">
      <nav
        aria-label="Main"
        className="flex items-center justify-between gap-4 py-5 border-b border-ink flex-wrap"
      >
        <Link
          href="/vaults"
          className="flex items-center gap-[10px] no-underline font-extrabold text-[21px] tracking-[-0.03em]"
        >
          <i aria-hidden className="inline-block w-[14px] h-[14px] bg-blue rounded-[2px]" />
          Overwrite
        </Link>
        <div className="flex items-center gap-4 sm:gap-7 order-3 sm:order-2 w-full sm:w-auto pt-3 sm:pt-0 border-t sm:border-t-0 border-rule">
          <NavLinks stakeEnabled={stakeEnabled} />
        </div>
        <div className="order-2 sm:order-3">
          <WalletButton />
        </div>
      </nav>
    </header>
  );
}
