# MM bond FAQ

The bond is the only thing standing between an anonymous address and the right to bid. Contract: `BondManager` ([source](../../contracts/src/BondManager.sol)), spec [§13](../SPEC.md).

**How much, and in what?**
25,000 USDG, posted once per address with `postBond(1)` (`1` = `BondKind.MM`). Approve the BondManager for 25,000 USDG first. `postBond` tops your leg up to the requirement, so if governance ever raises it you top up the difference rather than re-posting.

**Do I need one bond per vault or per auction?**
One bond per address covers every vault and every auction. Bid on NVDA and SPY in the same minute with the same bond.

**When is it locked?**
Your first bid in a series locks it for that series (`activeLocks` goes up by one). The lock is released:
- at `clear`, if you received no fill in that series;
- at settlement, if you did: once the series is SETTLED or RESOLVED anyone calls `AuctionHouse.releaseLocks(seriesId)`. The keeper does this routinely.

Locks count series, not option tokens. Selling or transferring the ERC-1155 does not release the bond.

**Can I keep bidding while locked?**
Yes. Locks only block withdrawal. Holding ten live series at once is fine.

**How do I get it back?**
1. Wait until `activeLocks(you) == 0` (every series you were filled in has settled).
2. `requestWithdraw(1)`. This starts a **7-day cooldown** and immediately sets `hasActiveMMBond` to false, so you cannot bid while it runs.
3. After the cooldown, `withdrawBond(1)` returns the full 25,000 USDG.

Changed your mind during the cooldown? `cancelWithdraw(1)` restores your eligibility on the spot.

**Why the cooldown?**
So a bidder cannot participate, misbehave and exit in the same week. The 7 days cover the longest possible series plus the 48-hour public window a slashing proposal needs (below).

**Can the bond be slashed, and by whom?**
Only by the protocol's TimelockController, with `slashBond(holder, kind, amount, evidenceURI)`:
- the call sits in the public timelock queue for **48 hours** before it can execute; you and everyone else can read it;
- the amount is capped at your bond; nothing else you hold is touched;
- proceeds go to the protocol treasury, not to the proposer;
- `evidenceURI` points at the public grounds.

Nobody else has a slashing path. The guardian keys can only pause new auctions and deposits. The keeper has no privilege over bonds at all. There is no admin function that moves your bond anywhere except back to you or, via a queued slash, to the treasury.

**What gets you slashed?**
Off-chain grounds, published with the proposal: fraud in the non-US-person attestation, demonstrated manipulation of a settlement TWAP, or malicious parameters if you also act as a curator. Losing money on a trade is not a ground. Nor is failing to claim.

**A slash left me below 25,000. Can I still bid?**
No: a leg below its requirement no longer qualifies. `postBond(1)` tops it back up.

**What about the attestation?**
Bidding requires a signed non-US-person attestation checked off-chain by the protocol's allowlist service. Nothing on-chain enforces it, and the BondManager has no field for it. Details come with your onboarding call.

**Is the bond earning anything?**
No. It sits in the BondManager as plain USDG. Size your desk's capital accordingly.

**What happens when the WRITE token launches?**
The required bond asset migrates from USDG to WRITE by a timelocked `startMigration` with a grace window of 30 days by intention (bounded on-chain to 90, extendable, never shortened). During the grace both assets qualify, so you post WRITE alongside your USDG and never have a gap. After the grace your USDG leg no longer counts and is withdrawable **without** cooldown, provided you have no active locks backed only by it. The WRITE amount is a fixed token count set by governance, never an oracle-priced figure, so a price swing cannot un-bond every MM at once. The landing page models this at roughly 50k USD of WRITE per MM; the actual number is a governance decision at launch.

**On testnet, where do I get 25,000 USDG?**
Mint it. Testnet USDG is a mock with an open `mint(address,uint256)`; see step 3 of the [bidding guide](BIDDING-GUIDE.md#try-it-on-testnet-in-10-minutes).

**Quick reference**

| Function | What it does |
|---|---|
| `postBond(1)` | post or top up to 25,000 USDG |
| `hasActiveMMBond(addr)` | true when you can bid |
| `activeLocks(addr)` | number of series currently locking you |
| `isLocked(addr, seriesId)` | is this series one of them |
| `status(addr, 1)` | `(amount, asset, unlockAt)`; `unlockAt > 0` means a withdrawal is pending |
| `requestWithdraw(1)` | start the 7-day cooldown; needs zero locks |
| `cancelWithdraw(1)` | abort it |
| `withdrawBond(1)` | collect after the cooldown |
| `BOND_COOLDOWN` | 604800 seconds, a constant |
