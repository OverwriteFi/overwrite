# overwrite / contracts

Foundry project for the overwrite protocol on Robinhood Chain (Arbitrum Orbit L2).

- solc 0.8.26, EVM `cancun`, `via_ir` off by default
- deps: forge-std, OpenZeppelin v5.1.0, solady (git submodules in `lib/`)
- profiles: `default` (256 fuzz runs), `ci` (10000 fuzz runs) -> `FOUNDRY_PROFILE=ci forge test`

The `Counter` files are the untouched `forge init` template; no protocol logic exists yet.
