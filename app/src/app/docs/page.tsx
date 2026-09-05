import type { Metadata } from "next";
import Link from "next/link";
import { Section } from "@/components/site/Bits";
import { PROTOCOL } from "@/lib/vault-defaults";

export const metadata: Metadata = { title: "Documentation" };

const usd = (n: number) => n.toLocaleString("en-US");

export default function DocsPage() {
  return (
    <div className="wrap pt-12 sm:pt-16">
      <h1 className="h1">How Overwrite works.</h1>
      <p className="lede">
        Everything on this page is a rule in the contracts, not a roadmap. Numbers are the live
        parameters on Robinhood Chain; where governance can move one, the bound is given.
      </p>
      <nav aria-label="On this page" className="mt-8 border-t-[1.5px] border-ink pt-3">
        <ul className="list-none m-0 p-0 flex flex-wrap gap-x-6 gap-y-2 text-[15px]">
          {[
            ["#week", "A week"],
            ["#auctions", "Auctions"],
            ["#settlement", "Settlement"],
            ["#deposits", "Deposits and withdrawals"],
            ["#caps", "Caps and the backstop"],
            ["#write", "The WRITE loop"],
            ["#tokens", "Stock Tokens"],
            ["#terms", "Terms"],
          ].map(([href, label]) => (
            <li key={href}>
              <a href={href} className="doc">
                {label}
              </a>
            </li>
          ))}
        </ul>
      </nav>

      {/* ── A week ─────────────────────────────────────────────────────────────────────────── */}
      <Section id="week" title="Two paydays a week." sub="Stock Tokens trade 24/7. Listed options stop at Friday's close. Overwrite sells the weekend as its own series, premium no other venue can collect.">
        <div className="scroll-x">
          <table className="tbl min-w-[680px]">
            <thead>
              <tr>
                <th scope="col">When (UTC)</th>
                <th scope="col">What happens</th>
                <th scope="col">Series</th>
              </tr>
            </thead>
            <tbody>
              <tr><td><b>Monday 14:00</b></td><td>Weekday auction opens. Bonded market makers bid for {PROTOCOL.auctionMinutes} minutes.</td><td>Weekday</td></tr>
              <tr><td><b>Monday 14:15</b></td><td>The auction clears. Premium is in the vault; the calls are live.</td><td>Weekday</td></tr>
              <tr><td><b>Friday 20:00</b></td><td>Weekday series expires at the New York close (21:00 UTC in winter) and settles on the Chainlink price.</td><td>Weekday</td></tr>
              <tr><td><b>Friday 20:10</b></td><td>Weekend auction opens, ten minutes after the close. Another {PROTOCOL.auctionMinutes} minutes of bidding.</td><td>Weekend</td></tr>
              <tr><td><b>Sunday 23:59</b></td><td>Weekend series expires and settles. The vault is idle until Monday.</td><td>Weekend</td></tr>
            </tbody>
          </table>
        </div>
        <p className="mt-6 max-w-[64ch]">
          Between Sunday night and Monday 14:00 the vault is <b>idle</b>: deposits and withdrawals go
          straight through. While a series is live they queue and execute at the next settlement (see{" "}
          <a href="#deposits" className="doc">deposits and withdrawals</a>). If no bid meets the floor,
          the week is simply skipped and the vault sells its upside next time.
        </p>
      </Section>

      {/* ── Auctions ───────────────────────────────────────────────────────────────────────── */}
      <Section id="auctions" title="Market makers compete for your upside." sub="A batch auction with one clearing price. More bidders, higher premium.">
        <div className="grid grid-cols-1 md:grid-cols-2 gap-x-12 gap-y-6">
          <div>
            <h3 className="h3 border-t-[1.5px] border-ink pt-3">The cap, set on a grid</h3>
            <p className="mt-2 text-[16px]">
              The keeper reads the reference price and places the strike a fixed distance above it:{" "}
              <b>+{PROTOCOL.strikeBounds.weekday[0] / 100}% to +{PROTOCOL.strikeBounds.weekday[1] / 100}%</b> for a weekday series,{" "}
              <b>+{PROTOCOL.strikeBounds.weekend[0] / 100}% to +{PROTOCOL.strikeBounds.weekend[1] / 100}%</b> for a weekend. Single names default to +8% / +5%, ETFs to +3% / +1%. The strike snaps up to the next {PROTOCOL.strikeGridBps / 100}% step, so it is never rounded against you.
            </p>
          </div>
          <div>
            <h3 className="h3 border-t-[1.5px] border-ink pt-3">A floor from live volatility</h3>
            <p className="mt-2 text-[16px]">
              Every auction carries a reserve price computed from thirty days of realised volatility. Bids below it do not count. The contracts enforce a hard minimum of {PROTOCOL.reserveDefaultBps.weekday / 100}% of spot on weekdays and {PROTOCOL.reserveDefaultBps.weekend / 100}% at weekends. Your upside never goes cheap: if the bids are not there, the vault keeps it.
            </p>
          </div>
          <div>
            <h3 className="h3 border-t-[1.5px] border-ink pt-3">Premium first, options second</h3>
            <p className="mt-2 text-[16px]">
              To bid, a market maker posts a bond of {usd(PROTOCOL.mmBondUsd)} USDG and escrows the full price of every bid in USDG before the auction clears. The vault fills the highest bids first and every winner pays the same clearing price. The money is in the vault the moment the auction ends.
            </p>
          </div>
          <div>
            <h3 className="h3 border-t-[1.5px] border-ink pt-3">What depositors receive</h3>
            <p className="mt-2 text-[16px]">
              The protocol keeps a {PROTOCOL.feeBps / 100}% fee (bound: at most 20%). The rest is credited to every share in the vault, claimable in USDG at any time. Shares queued for withdrawal do not earn on that week&apos;s auction.
            </p>
          </div>
        </div>
      </Section>

      {/* ── Settlement ─────────────────────────────────────────────────────────────────────── */}
      <Section id="settlement" title="Three outcomes. You get paid in all three." sub="Settlement runs on the official Chainlink feed for each Stock Token, entirely on-chain. Nothing is ever sold on an exchange to settle.">
        <div className="grid grid-cols-1 md:grid-cols-3 gap-x-10 gap-y-6">
          <div>
            <h3 className="h3 border-t-[1.5px] border-ink pt-3">Price drifts</h3>
            <p className="mt-2 text-[16px]">Below the cap at expiry, the calls expire worthless. You keep every token and the premium. This is most weeks, and it compounds: the vault writes the next one.</p>
          </div>
          <div>
            <h3 className="h3 border-t-[1.5px] border-ink pt-3">Price rallies</h3>
            <p className="mt-2 text-[16px]">Above the cap, the vault pays the difference in tokens: for each written token, <span className="pct">(price − cap) ÷ price</span> of it goes to the option holder. You keep every point of the move up to the cap, plus the premium on top.</p>
          </div>
          <div>
            <h3 className="h3 border-t-[1.5px] border-ink pt-3">Price dips</h3>
            <p className="mt-2 text-[16px]">You still hold every token and the premium cushions the move. Fully covered, no leverage, no liquidations, ever.</p>
          </div>
        </div>
        <div className="mt-8 max-w-[70ch]">
          <h3 className="h3">Which price settles</h3>
          <ol className="list-none m-0 p-0 mt-2 border-t-[1.5px] border-ink text-[16px]">
            <li className="py-3 border-b border-rule"><b>Weekday series:</b> the Chainlink round at or just before Friday&apos;s close, provided it is fresh.</li>
            <li className="py-3 border-b border-rule"><b>Weekend series:</b> Chainlink first; if the feed has not printed over the weekend, a one-hour Uniswap TWAP of the token against USDG, checked against the last Chainlink print. Otherwise the first Chainlink round after expiry, by Monday 15:00 UTC.</li>
            <li className="py-3 border-b border-rule"><b>No valid price:</b> the series halts. After {PROTOCOL.haltedTimeoutDays} days anyone can resolve it on the next valid Chainlink round, within a ±25% band of the last reference. Deposits and withdrawals wait for resolution; nothing is ever settled on a bad price.</li>
          </ol>
        </div>
      </Section>

      {/* ── Deposits ───────────────────────────────────────────────────────────────────────── */}
      <Section id="deposits" title="Deposits and withdrawals." sub="Straight through when the vault is idle. Queued, in order, when a series is live.">
        <div className="scroll-x">
          <table className="tbl min-w-[640px]">
            <thead>
              <tr>
                <th scope="col">You want to</th>
                <th scope="col">Vault idle (Sunday night to Monday 14:00, or a skipped week)</th>
                <th scope="col">Series live</th>
              </tr>
            </thead>
            <tbody>
              <tr>
                <td><b>Deposit</b></td>
                <td>Tokens become shares immediately, up to the vault&apos;s remaining capacity.</td>
                <td>Tokens are held by the vault and become shares at the next settlement, at the post-settlement share price. Cancel any time before then. If the cap is full when your turn comes, the request expires and you cancel to get the tokens back.</td>
              </tr>
              <tr>
                <td><b>Withdraw</b></td>
                <td>Tokens come straight back to your wallet.</td>
                <td>Your shares are escrowed (they stop earning), redeemed at the settlement share price, and the tokens then wait for you to claim. Cancel before settlement to get the shares back.</td>
              </tr>
              <tr>
                <td><b>Claim premium</b></td>
                <td colSpan={2}>Any time. Premium is USDG credited per share the moment an auction clears.</td>
              </tr>
            </tbody>
          </table>
        </div>
        <p className="note mt-3">
          Vault shares are a plain ERC-20 with 24 decimals. Their token value only changes at settlement, never in between.
        </p>
      </Section>

      {/* ── Caps ───────────────────────────────────────────────────────────────────────────── */}
      <Section id="caps" title="Capacity fills in order. Caps grow with the backstop." sub="Before the token, every vault has a fixed cap. After it, the backstop sets the ceiling.">
        <div className="grid grid-cols-1 md:grid-cols-2 gap-x-12 gap-y-6">
          <div>
            <h3 className="h3 border-t-[1.5px] border-ink pt-3">Today: fixed caps</h3>
            <p className="mt-2 text-[16px]">
              Each vault accepts deposits up to <b>{usd(PROTOCOL.fixedCapUsd)} USDG</b> of tokens, valued at the Chainlink price (or a 30-minute TWAP if the feed is more than 80 hours old). When the cap is full, new deposits queue for the next settlement.
            </p>
          </div>
          <div>
            <h3 className="h3 border-t-[1.5px] border-blue pt-3">After launch: caps from the backstop</h3>
            <p className="mt-2 text-[16px]">
              <span className="pct">cap = k × backstop value × vault weight</span>, with <b>k = {PROTOCOL.kDefault}</b> (governance may set it between {PROTOCOL.kMin} and {PROTOCOL.kMax}) and weights that sum to 100% across vaults, an equal split at the switch. A vault can keep a fixed ceiling on top; the lower number applies. Stake more WRITE and every vault&apos;s ceiling rises the same block.
            </p>
          </div>
        </div>
      </Section>

      {/* ── WRITE ──────────────────────────────────────────────────────────────────────────── */}
      <Section id="write" title="The WRITE loop." sub="One token, every lever. Demand for it is written into the contracts, not into a marketing plan. No revenue share, and none needed.">
        <ol className="list-none m-0 p-0 grid grid-cols-1 md:grid-cols-4 gap-x-8 gap-y-6">
          <li className="border-t-[1.5px] border-ink pt-3">
            <span className="k">1 · Backstop</span>
            <span className="stat-v">stake</span>
            <p className="mt-2 text-[15px]">Staked WRITE covers shortfalls. Unstaking takes a {PROTOCOL.unstakeCooldownDays}-day cooldown followed by a {PROTOCOL.unstakeClaimWindowDays}-day claim window. Slashing is capped at {PROTOCOL.maxSlashBps / 100}% per event, at most once every {PROTOCOL.slashIntervalDays} days.</p>
          </li>
          <li className="border-t-[1.5px] border-ink pt-3">
            <span className="k">2 · Capacity</span>
            <span className="stat-v">{PROTOCOL.kDefault}×</span>
            <p className="mt-2 text-[15px]">Vaults may hold at most {PROTOCOL.kDefault} times the backstop&apos;s value. Depositors fill that capacity with Stock Tokens.</p>
          </li>
          <li className="border-t-[1.5px] border-ink pt-3">
            <span className="k">3 · Fees in WRITE</span>
            <span className="stat-v">−{PROTOCOL.writeDiscountBps / 100}%</span>
            <p className="mt-2 text-[15px]">The {PROTOCOL.feeBps / 100}% protocol fee can be paid in WRITE at a {PROTOCOL.writeDiscountBps / 100}% discount, so most of it is. <b>{PROTOCOL.writeBurnShareBps / 100}%</b> of WRITE fees are burned.</p>
          </li>
          <li className="border-t-[1.5px] border-ink pt-3">
            <span className="k">4 · Bonds</span>
            <span className="stat-v">{usd(PROTOCOL.mmBondUsd)}</span>
            <p className="mt-2 text-[15px]">Market makers bond {usd(PROTOCOL.mmBondUsd)} USDG to bid and curators {usd(PROTOCOL.curatorBondUsd)} USDG to run a vault; both migrate to WRITE after launch, with a {PROTOCOL.bondCooldownDays}-day withdrawal cooldown. Less supply, more locked, a larger backstop: next week&apos;s ceiling is higher, and the loop runs again.</p>
          </li>
        </ol>
        <p className="note mt-6 max-w-[80ch]">
          Supply: 1,000,000,000 WRITE. 30% streams to the safety module over four years, 25% is escrowed for the launch pool, 20% vests to the treasury over three years with no cliff, 15% vests to the team over three years with a one-year cliff, 10% funds points and bond grants through Merkle rounds. Every parameter above sits behind a 48-hour timelock.
        </p>
      </Section>

      {/* ── Stock Tokens ───────────────────────────────────────────────────────────────────── */}
      <Section id="tokens" title="Stock Tokens, dividends and splits." sub="Balances never change. The multiplier does.">
        <p className="max-w-[70ch] text-[16px]">
          Robinhood Stock Tokens follow ERC-8056: a dividend or a split does not move your balance, it
          moves the token&apos;s <b>shares-per-token multiplier</b>. The Chainlink feed already prices one
          raw token with that multiplier applied, so the vault never adjusts anything. That is why every
          token figure in this app carries a <i>shares equivalent</i> next to it, and why a vault
          shows a notice when a multiplier change is scheduled. Strikes are per token and stay fixed for
          the life of a series.
        </p>
      </Section>

      <Section id="terms" title="Terms." sub="Short, because the rest is on-chain.">
        <p className="max-w-[70ch] text-[16px]">
          Overwrite is a set of immutable smart contracts on Robinhood Chain operated by no one. Using
          them is your own decision. Premium is set at auction
          each week; any figure marked <i>model estimate</i> is a calculation, not an offer. See the
          disclosures in the footer of every page. Contract addresses are listed on Blockscout via the
          footer link, and the protocol specification lives in the public repository.
        </p>
        <p className="mt-6">
          <Link href="/vaults" className="btn btn-blue">
            Open the vaults
          </Link>
        </p>
      </Section>
    </div>
  );
}
