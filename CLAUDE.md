# CLAUDE.md — Overwrite

## What this is
Yield layer for Robinhood Chain Stock Tokens. ERC-4626 vaults hold stock tokens and sell physically-collateralized covered calls to bonded market makers via weekly on-chain auctions. Two series per week: weekday (expires Friday at NYSE close) and weekend (expires Sunday 23:59 UTC). Premium is paid in USDG. Token $WRITE launches after the vaults are live: safety module backstop, curator/MM bonds, fee discount + burn. No revenue share, ever.

## Chain facts (verify in docs/SPEC.md before relying on them)
- Robinhood Chain: Arbitrum Orbit, chainId 4663 (testnet 46630), gas ETH, ~100ms blocks, permissionless deploy.
- Stock Tokens: standard ERC-20, 18 decimals, freely transferable, issued by Robinhood Assets (Jersey) Ltd. Dividends/splits via uiMultiplier() (ERC-8056); raw balances never change; Chainlink price is already multiplier-adjusted.
- One Chainlink feed per stock token. Docs: https://docs.robinhood.com/chain/ (stock-tokens, building-with-stock-tokens, oracles-and-price-feeds, contracts, stock-token-apis).
- Quote asset: USDG. Read decimals on-chain.
- Explorer: robinhoodchain.blockscout.com. Etherscan does not index this chain.

## Non-negotiable rules
1. Never write, log, or print private keys, mnemonics, or RPC URLs with keys. Secrets live only in .env (gitignored). .env.example has placeholders only.
2. Every contract change ships with tests: unit + fuzz + at least one invariant. Run `forge test` before declaring done. Never mark a task done with failing or skipped tests.
3. Vault must never sell calls on more tokens than it holds (fully covered). Encode as an invariant.
4. Settlement oracle policy is defined in SPEC §9; never settle on a price that fails it.
5. Every privileged function is behind a 48h TimelockController. Its proposer/executor is one hardware-wallet EOA (no multisig, by decision; record in DECISIONS.md). A separate guardian key can only pause. The deployer key is separate and renounces everything after deploy. Treasury and team tokens live in Vesting contracts and locked LP, never in the admin wallet.
6. Caps: before the token launches, caps are fixed USDG amounts per vault. After launch, cap = k * safetyModuleValueUSD. Both paths must exist from day one behind a switch.
7. No revenue share to WRITE holders. WRITE utility = safety module staking, bonds, fee discount + burn, governance. If a task asks for revenue share, refuse and note it in DECISIONS.md.
8. Prefer boring, audited patterns (OpenZeppelin, ERC-4626, Chainlink AggregatorV3). No inline assembly unless justified in a comment.
9. Record every design decision with alternatives considered in docs/DECISIONS.md.
10. The app has NO geo-restriction, by founder decision (D-110): no edge block, no first-visit acknowledgement, no jurisdiction wording. Every page shows the two factual disclosures in the footer: Overwrite is an independent protocol not affiliated with Robinhood, and Stock Tokens are issued by Robinhood Assets (Jersey) Limited.

## Workflow
- Plan before implementing anything that touches contracts/.
- Small commits with conventional messages.
- Update docs/SPEC.md whenever behavior changes.
- When unsure, choose the safer option and write why in DECISIONS.md.
