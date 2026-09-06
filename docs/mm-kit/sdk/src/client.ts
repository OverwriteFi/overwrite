import {
  createPublicClient,
  createWalletClient,
  http,
  type Account,
  type Address,
  type Hash,
  type PublicClient,
  type WalletClient,
  type Chain,
  type Transport,
} from "viem";
import { auctionHouseAbi, bondManagerAbi, optionTokenAbi, vaultAbi, erc20Abi, feedAbi } from "./abi.js";
import { chainById, deployments, type Deployment } from "./addresses.js";
import { AuctionState, BondKind, SeriesState, escrowFor, WAD } from "./units.js";

export interface ClientOptions {
  rpcUrl: string;
  chainId?: 46630 | 4663;
  /** viem account (privateKeyToAccount, a Ledger/Trezor account, or a JSON-RPC account). Omit for read-only. */
  account?: Account;
  /** Override the address book, e.g. for an anvil fork. */
  deployment?: Deployment;
}

export interface OpenAuction {
  seriesId: bigint;
  vault: Address;
  kind: "WEEKDAY" | "WEEKEND";
  state: (typeof AuctionState)[number];
  auctionOpen: number;
  auctionClose: number;
  expiry: number;
  sRef: bigint; // USD 8 dec
  strike: bigint; // USD 8 dec
  offeredQty: bigint; // 1e18 = one option
  reservePrice: bigint; // USDG 6 dec per option
  clearingPrice: bigint;
  filledQty: bigint;
  feeBps: number;
  /** Seconds until close, negative once closed. */
  secondsLeft: number;
}

export interface BookEntry {
  bidId: number;
  bidder: Address;
  qty: bigint;
  price: bigint;
  escrow: bigint;
}

/**
 * Everything a market maker does against Overwrite, in one object. Every write is simulated first so a
 * revert surfaces as a decoded error (`NoActiveBond`, `BelowReserve(price, reserve)`, ...) before gas
 * is spent, then sent and awaited to a receipt.
 */
export class OverwriteClient {
  readonly pub: PublicClient<Transport, Chain>;
  readonly wallet?: WalletClient<Transport, Chain, Account>;
  readonly d: Deployment;
  readonly account?: Account;

  constructor(opts: ClientOptions) {
    const chainId = opts.chainId ?? 46630;
    const chain = { ...chainById[chainId], rpcUrls: { default: { http: [opts.rpcUrl] } } };
    this.d = opts.deployment ?? deployments[chainId];
    if (!this.d) throw new Error(`no deployment for chain ${chainId}`);
    this.pub = createPublicClient({ chain, transport: http(opts.rpcUrl) });
    if (opts.account) {
      this.account = opts.account;
      this.wallet = createWalletClient({ account: opts.account, chain, transport: http(opts.rpcUrl) });
    }
  }

  get me(): Address {
    if (!this.account) throw new Error("read-only client: pass `account`");
    return this.account.address;
  }

  // ───────────────────────────── bond ─────────────────────────────

  async bondStatus(who: Address = this.me) {
    const [active, locks, [amount, asset, unlockAt], required] = await Promise.all([
      this.pub.readContract({ address: this.d.bondManager, abi: bondManagerAbi, functionName: "hasActiveMMBond", args: [who] }),
      this.pub.readContract({ address: this.d.bondManager, abi: bondManagerAbi, functionName: "activeLocks", args: [who] }),
      this.pub.readContract({ address: this.d.bondManager, abi: bondManagerAbi, functionName: "status", args: [who, BondKind.MM] }),
      this.pub.readContract({ address: this.d.bondManager, abi: bondManagerAbi, functionName: "requiredAmount", args: [BondKind.MM] }),
    ]);
    return { canBid: active, activeLocks: locks, posted: amount, asset, withdrawUnlockAt: Number(unlockAt), required };
  }

  /** Approve and post (or top up to) the MM bond. Idempotent: returns null if already bonded. */
  async postBond(): Promise<Hash | null> {
    const { canBid, posted, required, withdrawUnlockAt } = await this.bondStatus();
    if (withdrawUnlockAt > 0) throw new Error("withdrawal pending: call cancelWithdraw() first");
    if (canBid && posted >= required) return null;
    await this.ensureAllowance(this.d.bondManager, required - posted);
    return this.write({ address: this.d.bondManager, abi: bondManagerAbi, functionName: "postBond", args: [BondKind.MM] });
  }

  requestBondWithdraw() {
    return this.write({ address: this.d.bondManager, abi: bondManagerAbi, functionName: "requestWithdraw", args: [BondKind.MM] });
  }
  cancelBondWithdraw() {
    return this.write({ address: this.d.bondManager, abi: bondManagerAbi, functionName: "cancelWithdraw", args: [BondKind.MM] });
  }
  withdrawBond() {
    return this.write({ address: this.d.bondManager, abi: bondManagerAbi, functionName: "withdrawBond", args: [BondKind.MM] });
  }

  // ───────────────────────────── auctions ─────────────────────────────

  /** Latest series of a vault, whatever its state. */
  async auction(vaultOrSymbol: Address | string): Promise<OpenAuction> {
    const vault = this.vaultAddress(vaultOrSymbol);
    const id = await this.pub.readContract({ address: this.d.auctionHouse, abi: auctionHouseAbi, functionName: "currentAuction", args: [vault] });
    return this.auctionById(id);
  }

  /** Any series by id. `state` is NONE for an id that was never opened. */
  async auctionById(id: bigint): Promise<OpenAuction> {
    const a = await this.pub.readContract({ address: this.d.auctionHouse, abi: auctionHouseAbi, functionName: "auctions", args: [id] });
    const now = Math.floor(Date.now() / 1000);
    return {
      seriesId: id,
      vault: a.vault,
      kind: a.kind === 0 ? "WEEKDAY" : "WEEKEND",
      state: AuctionState[a.state],
      auctionOpen: Number(a.auctionOpen),
      auctionClose: Number(a.auctionClose),
      expiry: Number(a.expiry),
      sRef: a.sRef,
      strike: a.strike,
      offeredQty: a.offeredQty,
      reservePrice: a.reservePrice,
      clearingPrice: a.clearingPrice,
      filledQty: a.filledQty,
      feeBps: a.feeBps,
      secondsLeft: Number(a.auctionClose) - now,
    };
  }

  /** Every vault's current auction, filtered to the ones that are OPEN right now. */
  async openAuctions(): Promise<OpenAuction[]> {
    const all = await Promise.all(Object.keys(this.d.vaults).map((s) => this.auction(s)));
    return all.filter((a) => a.state === "OPEN" && a.secondsLeft > 0);
  }

  async book(seriesId: bigint): Promise<BookEntry[]> {
    const bs = await this.pub.readContract({ address: this.d.auctionHouse, abi: auctionHouseAbi, functionName: "bids", args: [seriesId] });
    return bs
      .map((b, i) => ({ bidId: i, bidder: b.bidder, qty: b.qty, price: b.price, escrow: b.escrow }))
      .sort((x, y) => (y.price === x.price ? x.bidId - y.bidId : y.price > x.price ? 1 : -1));
  }

  /** Runs the real clearing routine as a view: what the auction would do if `clear` ran now. */
  async previewClear(seriesId: bigint) {
    const [clearingPrice, filledQty, premiumGross, willSkip] = await this.pub.readContract({
      address: this.d.auctionHouse, abi: auctionHouseAbi, functionName: "previewClear", args: [seriesId],
    });
    return { clearingPrice, filledQty, premiumGross, willSkip };
  }

  /** Fresh `S_ref` the AuctionHouse would use to open right now, plus the feed's latest round. */
  async reference(vaultOrSymbol: Address | string) {
    const vault = this.vaultAddress(vaultOrSymbol);
    const entry = Object.values(this.d.vaults).find((v) => v.vault === vault);
    const [sRef, round] = await Promise.all([
      this.pub.readContract({ address: this.d.auctionHouse, abi: auctionHouseAbi, functionName: "referencePrice", args: [vault] }),
      entry ? this.pub.readContract({ address: entry.feed, abi: feedAbi, functionName: "latestRoundData" }) : undefined,
    ]);
    return { sRef, latestAnswer: round?.[1], updatedAt: round ? Number(round[3]) : undefined };
  }

  async limits() {
    const [minBidQty, maxBidsPerBidder, clearGrace] = await Promise.all([
      this.pub.readContract({ address: this.d.auctionHouse, abi: auctionHouseAbi, functionName: "minBidQty" }),
      this.pub.readContract({ address: this.d.auctionHouse, abi: auctionHouseAbi, functionName: "maxBidsPerBidder" }),
      this.pub.readContract({ address: this.d.auctionHouse, abi: auctionHouseAbi, functionName: "clearGrace" }),
    ]);
    return { minBidQty, maxBidsPerBidder: Number(maxBidsPerBidder), clearGrace: Number(clearGrace) };
  }

  // ───────────────────────────── bidding ─────────────────────────────

  /**
   * Place one bid. `qty` in 1e18 units, `price` in USDG (6 dec) per option. Tops up the USDG allowance
   * for the escrow if needed. Simulation decodes `BelowReserve`, `NoActiveBond`, `AuctionClosed` etc.
   */
  async bid(seriesId: bigint, qty: bigint, price: bigint): Promise<Hash> {
    await this.ensureAllowance(this.d.auctionHouse, escrowFor(qty, price));
    return this.write({ address: this.d.auctionHouse, abi: auctionHouseAbi, functionName: "bid", args: [seriesId, qty, price] });
  }

  /** Place a ladder of bids sequentially (nonce-safe). Stops at the first failure and returns what landed. */
  async bidLadder(seriesId: bigint, ladder: { qty: bigint; price: bigint }[]): Promise<Hash[]> {
    const total = ladder.reduce((s, b) => s + escrowFor(b.qty, b.price), 0n);
    await this.ensureAllowance(this.d.auctionHouse, total);
    const out: Hash[] = [];
    for (const b of ladder) {
      out.push(await this.write({ address: this.d.auctionHouse, abi: auctionHouseAbi, functionName: "bid", args: [seriesId, b.qty, b.price] }));
    }
    return out;
  }

  /** Permissionless. The keeper normally does it; call it yourself if you want to be sure it clears in time. */
  clear(seriesId: bigint) {
    return this.write({ address: this.d.auctionHouse, abi: auctionHouseAbi, functionName: "clear", args: [seriesId] });
  }

  // ───────────────────────────── after clear ─────────────────────────────

  async position(seriesId: bigint, who: Address = this.me) {
    const a = await this.auctionById(seriesId);
    const [allocation, refund, held, vs] = await Promise.all([
      this.pub.readContract({ address: this.d.auctionHouse, abi: auctionHouseAbi, functionName: "claimableOptions", args: [seriesId, who] }),
      this.pub.readContract({ address: this.d.auctionHouse, abi: auctionHouseAbi, functionName: "refundable", args: [who] }),
      this.pub.readContract({ address: this.d.optionToken, abi: optionTokenAbi, functionName: "balanceOf", args: [who, seriesId] }),
      this.pub.readContract({ address: a.vault, abi: vaultAbi, functionName: "series", args: [seriesId] }),
    ]);
    const settled = vs.state === 4 || vs.state === 6;
    const perOption = vs.payoutPerOption;
    return {
      seriesState: SeriesState[vs.state],
      unmintedAllocation: allocation,
      optionTokensHeld: held,
      refundableUsdg: refund, // across all series
      settled,
      settlementPrice: vs.settlementPrice,
      payoutPerOption: perOption,
      /** Stock tokens you would receive for allocation + held tokens once settled. */
      payoutTokens: settled ? ((allocation + held) * perOption) / WAD : undefined,
    };
  }

  withdrawRefund(to: Address = this.me) {
    return this.write({ address: this.d.auctionHouse, abi: auctionHouseAbi, functionName: "withdrawRefund", args: [to] });
  }

  /** Mint your allocation as ERC-1155 (to hedge, transfer or custody). Works while LIVE, HALTED, SETTLED or RESOLVED. */
  claimOptions(seriesId: bigint, to: Address = this.me) {
    return this.write({ address: this.d.auctionHouse, abi: auctionHouseAbi, functionName: "claimOptions", args: [seriesId, to] });
  }

  /** Skip minting: turn the unminted allocation straight into Stock Tokens. Reverts until SETTLED or RESOLVED. */
  claimPayout(seriesId: bigint, to: Address = this.me) {
    return this.write({ address: this.d.auctionHouse, abi: auctionHouseAbi, functionName: "claimPayout", args: [seriesId, to] });
  }

  /** For option tokens you already hold (minted or bought): burn and receive the payout. */
  claimTokens(seriesId: bigint, qty: bigint, to: Address = this.me) {
    return this.write({ address: this.d.optionToken, abi: optionTokenAbi, functionName: "claim", args: [seriesId, qty, to] });
  }

  /** Permissionless, idempotent: frees every filled bidder's bond once the series is settled. */
  releaseLocks(seriesId: bigint) {
    return this.write({ address: this.d.auctionHouse, abi: auctionHouseAbi, functionName: "releaseLocks", args: [seriesId] });
  }

  /**
   * One call after settlement: payout for the unminted allocation, payout for any tokens held, refund
   * withdrawal, and a lock release. Each step is skipped when there is nothing to do.
   */
  async settleUp(seriesId: bigint): Promise<Hash[]> {
    const p = await this.position(seriesId);
    const txs: Hash[] = [];
    if (!p.settled) throw new Error(`series ${seriesId} is ${p.seriesState}, not settled yet`);
    if (p.unmintedAllocation > 0n) txs.push(await this.claimPayout(seriesId));
    if (p.optionTokensHeld > 0n) txs.push(await this.claimTokens(seriesId, p.optionTokensHeld));
    if (p.refundableUsdg > 0n) txs.push(await this.withdrawRefund());
    const locked = await this.pub.readContract({ address: this.d.bondManager, abi: bondManagerAbi, functionName: "isLocked", args: [this.me, seriesId] });
    if (locked) txs.push(await this.releaseLocks(seriesId));
    return txs;
  }

  // ───────────────────────────── testnet ─────────────────────────────

  /** Testnet only: USDG is a mock with an open mint. Throws on a real deployment. */
  mintTestUsdg(amount: bigint, to: Address = this.me) {
    if (!this.d.usdgIsMock) throw new Error("USDG is not a mock on this chain");
    return this.write({ address: this.d.usdg, abi: erc20Abi, functionName: "mint", args: [to, amount] });
  }

  usdgBalance(who: Address = this.me) {
    return this.pub.readContract({ address: this.d.usdg, abi: erc20Abi, functionName: "balanceOf", args: [who] });
  }

  // ───────────────────────────── internals ─────────────────────────────

  vaultAddress(vaultOrSymbol: Address | string): Address {
    if (vaultOrSymbol.startsWith("0x")) return vaultOrSymbol as Address;
    const v = this.d.vaults[vaultOrSymbol.toUpperCase()];
    if (!v) throw new Error(`unknown vault symbol ${vaultOrSymbol}; known: ${Object.keys(this.d.vaults).join(", ")}`);
    return v.vault;
  }

  /** Raises the USDG allowance for `spender` to at least `needed`. Exact amounts, no infinite approvals. */
  async ensureAllowance(spender: Address, needed: bigint): Promise<Hash | null> {
    if (needed <= 0n) return null;
    const have = await this.pub.readContract({ address: this.d.usdg, abi: erc20Abi, functionName: "allowance", args: [this.me, spender] });
    if (have >= needed) return null;
    return this.write({ address: this.d.usdg, abi: erc20Abi, functionName: "approve", args: [spender, needed] });
  }

  /** simulate → write → wait. Reverts throw with the decoded custom error name and args. */
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  private async write(params: any): Promise<Hash> {
    if (!this.wallet || !this.account) throw new Error("read-only client: pass `account`");
    const { request } = await this.pub.simulateContract({ ...params, account: this.account });
    const hash = await this.wallet.writeContract(request);
    const receipt = await this.pub.waitForTransactionReceipt({ hash });
    if (receipt.status !== "success") throw new Error(`tx ${hash} reverted`);
    return hash;
  }
}
