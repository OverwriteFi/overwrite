# overwrite

DeFi protocol on **Robinhood Chain** (Arbitrum Orbit L2). Gas is paid in ETH.

| network | chainId |
|---------|---------|
| mainnet | 4663    |
| testnet | 46630   |

## Folder map

```
overwrite/
├── contracts/   Foundry project (solc 0.8.26, OpenZeppelin v5, solady) — on-chain protocol
├── keeper/      Node 22 + TypeScript off-chain keeper (viem, zod, pino, node-cron)
├── points/      Node 22 + TypeScript points ledger/indexer (better-sqlite3)
├── app/         Next.js App Router frontend (Tailwind, wagmi, viem, react-query; injected + WalletConnect)
├── docs/        SPEC.md · THREAT-MODEL.md · DECISIONS.md · RUNBOOK.md · TOKENOMICS.md
├── .githooks/   pre-commit secret scanner (enabled via core.hooksPath)
├── .claude/     Claude Code settings + PreToolUse guard for .env files
├── .env.example placeholders only — copy to .env (never committed)
└── CLAUDE.md    working agreement for Claude Code sessions
```

## Setup

```bash
git clone --recurse-submodules <repo> overwrite && cd overwrite
git config core.hooksPath .githooks
cp .env.example .env            # then fill in values by hand
(cd contracts && forge build)
(cd keeper && npm install)
(cd points && npm install)
(cd app && npm install)
```

Foundry lives in `~/.foundry/bin`; add it to `PATH` if `forge` is not found.

## Common commands

| where       | command                                    | what                                  |
|-------------|--------------------------------------------|---------------------------------------|
| contracts/  | `forge build` / `forge test`               | compile / test (256 fuzz runs)        |
| contracts/  | `FOUNDRY_PROFILE=ci forge test`            | CI profile, 10000 fuzz runs           |
| keeper/     | `npm run dev` / `npm run lint`             | run with tsx watch / eslint           |
| points/     | `npm run dev`                              | open the SQLite ledger                |
| app/        | `npm run dev`                              | Next.js dev server                    |

## Guardrails

- **pre-commit hook** (`.githooks/pre-commit`) rejects staged content containing `0x` + 64 hex chars
  or a non-empty private-key assignment. Run `git config core.hooksPath .githooks` once per clone.
- **Claude Code hook** (`.claude/hooks/guard-env.mjs`) refuses Write/Edit/Bash writes to any path
  containing `.env` except a file named exactly `.env.example`.
- `.gitignore` excludes `.env`, `.env.*`, `broadcast/`, `cache/`, `out/`, `node_modules/`.
