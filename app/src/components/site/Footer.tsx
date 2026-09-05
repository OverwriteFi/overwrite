import Link from "next/link";
import { explorerUrl } from "@/lib/chains";
import { deployment } from "@/lib/deployment";

/** The only place disclosures live. Rendered on every page (CLAUDE.md rule 10). */
export function Footer() {
  return (
    <footer className="wrap pt-14 pb-16 text-[13.5px] text-gray mt-24">
      <div className="grid grid-cols-1 md:grid-cols-[2fr_1fr] gap-10 border-t border-rule pt-8">
        <div>
          <p className="max-w-[78ch] leading-[1.55]">
            Overwrite is an independent protocol deployed on Robinhood Chain. It is not affiliated
            with, operated by, or endorsed by Robinhood. Stock Tokens are tokenised debt securities
            issued by Robinhood Assets (Jersey) Limited; they provide economic exposure to underlying
            securities and do not confer ownership or shareholder rights.
          </p>
        </div>
        <ul className="list-none m-0 p-0 flex flex-col gap-2">
          <li>
            <Link href="/docs" className="no-underline hover:text-ink">
              Documentation
            </Link>
          </li>
          <li>
            <a
              href={explorerUrl("address", deployment.core.auctionHouse)}
              target="_blank"
              rel="noreferrer"
              className="no-underline hover:text-ink"
            >
              Contracts on Blockscout
            </a>
          </li>
          <li>
            <a href="https://x.com/overwritefi" target="_blank" rel="noreferrer" className="no-underline hover:text-ink">
              X
            </a>
          </li>
          <li>
            <Link href="/docs#terms" className="no-underline hover:text-ink">
              Terms
            </Link>
          </li>
        </ul>
      </div>
    </footer>
  );
}
