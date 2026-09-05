import Link from "next/link";
import { Calculator } from "@/components/landing/Calculator";
import { GetInLine } from "@/components/landing/GetInLine";
import { Ledger } from "@/components/landing/Ledger";
import { WriteLoop } from "@/components/landing/WriteLoop";
import { getLanding } from "@/lib/reads/landing";
import { getLoop } from "@/lib/reads/loop";

/** Marketing home. Copy and structure are landing/index.html; the instruments read the chain. */
export const revalidate = 30;

export default async function Home() {
  const [{ calc }, loop] = await Promise.all([getLanding(), getLoop()]);

  return (
    <>
      <section className="wrap hero">
        <div>
          <h1>Make your Stock Tokens pay you every week.</h1>
          <p className="lede">
            Overwrite is the yield layer for tokenized stocks on Robinhood Chain. Deposit NVDA, TSLA or QQQ, and market
            makers bid for your upside every week, paying premium in USDG up front. Two auctions a week, including the
            weekend, which no exchange on earth can sell.
          </p>
          <div className="cta">
            <Link className="btn btn-blue" href="/vaults">
              Open app
            </Link>
            <a className="btn btn-plain" href="#write">
              See the WRITE loop
            </a>
            <Link className="doc" href="/docs">
              Documentation
            </Link>
          </div>
        </div>

        <Calculator vaults={calc} />
      </section>

      <div className="wrap">
        <p className="claim">
          190+ Stock Tokens trade around the clock on Robinhood Chain. Not one of them wrote a single option. Until now.
        </p>
      </div>

      <section className="wrap sec" id="tradeoff">
        <h2>Three outcomes. You get paid in all three.</h2>
        <p className="sub">
          Premium is paid the moment the auction clears, before the week even starts. Whatever the price does after
          that, it is already yours.
        </p>
        <div className="three">
          <div>
            <h3>Price drifts</h3>
            <p>
              You collect the premium while everyone else waits. This is most weeks, and it compounds: the option
              expires, the vault writes the next one.
            </p>
          </div>
          <div>
            <h3>Price rallies</h3>
            <p>
              You keep every point of the move up to the cap, plus the premium on top. Set the cap higher when you want
              more of the run.
            </p>
          </div>
          <div>
            <h3>Price dips</h3>
            <p>
              You still hold every token, and the premium cushions the move. Fully covered, no leverage, no
              liquidations, ever.
            </p>
          </div>
        </div>
      </section>

      <section className="wrap sec" id="write">
        <WriteLoop loop={loop} />
        <div className="not">
          <h3>One token, every lever</h3>
          <p>
            WRITE sets the caps, bonds the market makers and curators, and takes the fees at a discount. Demand for it
            is written into the contracts, not into a marketing plan. No revenue share, and none needed.
          </p>
        </div>
      </section>

      <div className="band">
        <section className="wrap sec" id="series">
          <h2>Two paydays a week.</h2>
          <p className="sub">
            Stock Tokens trade 24/7. Listed options stop at Friday&apos;s close. Overwrite sells the weekend as its own
            series, premium no other venue can collect.
          </p>
          <table className="series">
            <thead>
              <tr>
                <th scope="col">Series</th>
                <th scope="col">Auction</th>
                <th scope="col">Expires</th>
                <th scope="col">Settles on</th>
                <th scope="col">Default cap</th>
              </tr>
            </thead>
            <tbody>
              <tr>
                <td>Weekday</td>
                <td>Monday 14:00 UTC, 15 minutes</td>
                <td>Friday at the New York close</td>
                <td>Chainlink price feed</td>
                <td className="b">+8% above spot</td>
              </tr>
              <tr>
                <td>Weekend</td>
                <td>Friday, 10 minutes after the close</td>
                <td>Sunday 23:59 UTC</td>
                <td>Chainlink, with Uniswap TWAP fallback</td>
                <td className="b">+5% above spot</td>
              </tr>
            </tbody>
          </table>
        </section>
      </div>

      <section className="wrap sec" id="vaults">
        <h2>Vaults.</h2>
        <p className="sub">
          One vault per Stock Token, fully covered, no leverage. Capacity is set by the backstop and grows as more WRITE
          is staked, so the vaults you see are the ones filling first.
        </p>
        <Ledger vaults={calc} />
      </section>

      <section className="wrap sec" id="makers">
        <h2>Market makers compete for your upside.</h2>
        <div className="two">
          <div>
            <p>
              Every week, bonded market makers bid against each other for the right to buy your upside. It is a batch
              auction: the vault fills the highest bids first, and every winner pays the same clearing price. More
              bidders, higher premium.
            </p>
            <p>
              Bids are escrowed in USDG before the auction clears, so the money is in the vault the moment it ends.
              Premium first, options second.
            </p>
          </div>
          <div>
            <p>
              The vault sets a floor from live volatility. Your upside never goes cheap: if the bids are not there, the
              vault simply keeps it and sells it next week.
            </p>
            <p>
              Settlement runs on the official Chainlink feed for each Stock Token, entirely on-chain. Nothing is ever
              sold on an exchange to settle.
            </p>
          </div>
        </div>
      </section>

      <section className="wrap sec" id="join">
        <div className="end">
          <div>
            <h2>Capacity fills in order. Get in line.</h2>
            <p>
              The first vaults open with the first backstop. Leave an address and you will know the moment the first
              auction clears, with the premium it paid.
            </p>
          </div>
          <GetInLine />
        </div>
      </section>
    </>
  );
}
