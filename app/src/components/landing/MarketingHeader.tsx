import Link from "next/link";

/** The landing nav, verbatim from landing/index.html. Anchors scroll the page; "Open app" leaves it. */
export function MarketingHeader() {
  return (
    <header className="wrap">
      <nav className="nav" aria-label="Main">
        <Link className="mark" href="/">
          <i aria-hidden="true" />
          Overwrite
        </Link>
        <ul>
          <li>
            <a href="#tradeoff">How it works</a>
          </li>
          <li>
            <a href="#write">The loop</a>
          </li>
          <li>
            <a href="#vaults">Vaults</a>
          </li>
          <li>
            <a href="#makers">Market makers</a>
          </li>
          <li>
            <Link className="btn btn-blue" href="/vaults">
              Open app
            </Link>
          </li>
        </ul>
      </nav>
    </header>
  );
}
