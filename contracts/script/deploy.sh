#!/bin/sh
# One command deploys the whole system to one chain.
#
#   ./script/deploy.sh 46630 --private-key     # testnet, key from .env
#   ./script/deploy.sh 4663  --ledger          # mainnet, hardware wallet
#   ./script/deploy.sh 46630 --private-key --dry-run
#
# It exists because an external library's address is resolved at COMPILE time: `TickMath` has to be on chain
# and passed as `--libraries` before `script/Deploy.s.sol` is even compiled, so it cannot deploy itself
# (D-058). This wrapper deploys it, records it in `config/<chain>.json`, and passes the same `--libraries`
# string to every later invocation.
#
# The private key is only ever read into a shell variable from .env and passed to forge unexpanded. It is
# never echoed, never written to a file and never part of a printed command (CLAUDE.md rule 1). Tracing is
# switched off explicitly for the same reason.
set -eu
set +x

usage() {
  echo "usage: $0 <chainId> (--private-key | --ledger) [--dry-run] [--no-verify]" >&2
  exit 2
}

[ $# -ge 2 ] || usage
CHAIN="$1"
SIGNER="$2"
shift 2

DRY_RUN=0
VERIFY=1
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --no-verify) VERIFY=0 ;;
    *) usage ;;
  esac
done

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
[ -f "config/$CHAIN.json" ] || { echo "no config/$CHAIN.json" >&2; exit 1; }

# .env lives at the repo root and is gitignored; .env.example has placeholders only.
[ -f "../.env" ] || { echo "no ../.env -- copy .env.example and fill it in" >&2; exit 1; }
set -a
# shellcheck disable=SC1091
. ../.env
set +a

export PATH="$HOME/.foundry/bin:$PATH"

# ── rpc ──────────────────────────────────────────────────────────────────────
case "$CHAIN" in
  4663)  RPC="${ROBINHOOD_RPC_URL:-}" ;;
  46630) RPC="${ROBINHOOD_TESTNET_RPC_URL:-}" ;;
  *)     echo "unknown chain $CHAIN (expected 4663 or 46630)" >&2; exit 1 ;;
esac
[ -n "$RPC" ] || { echo "no RPC URL in .env for chain $CHAIN" >&2; exit 1; }
case "$RPC" in http*) ;; *) RPC="https://$RPC" ;; esac

# ── signer ───────────────────────────────────────────────────────────────────
# Held in "$@" so the key is never interpolated into a string that could be printed.
case "$SIGNER" in
  --ledger)
    set -- --ledger
    ;;
  --private-key)
    [ -n "${DEPLOYER_PRIVATE_KEY:-}" ] || { echo "DEPLOYER_PRIVATE_KEY is empty in .env" >&2; exit 1; }
    set -- --private-key "$DEPLOYER_PRIVATE_KEY"
    ;;
  *) usage ;;
esac

# ── stage 0: TickMath, deployed and linked before anything else (D-058) ──────
TICKMATH=$(sed -n 's/^[[:space:]]*"tickMath": "\(0x[0-9a-fA-F]*\)".*/\1/p' "config/$CHAIN.json")
if [ "$TICKMATH" = "0x0000000000000000000000000000000000000000" ]; then
  # Deployed for real even under --dry-run: an external library's address is a compile-time input, so there
  # is nothing to simulate against without it. TickMath is a pure library -- no state, no owner, no privileges
  # -- so deploying it early costs one small transaction and commits to nothing.
  if [ "$DRY_RUN" = "1" ]; then
    echo "note: --dry-run still deploys TickMath, because the link is a compile-time input."
  fi
  echo "==> deploying TickMath"
  OUT=$(forge create src/libraries/TickMath.sol:TickMath --rpc-url "$RPC" --broadcast --json "$@")
  # `forge create --json` pretty-prints, so strip whitespace first and take the quoted value.
  TICKMATH=$(printf %s "$OUT" | tr -d "[:space:]" | sed -n "s/.*\"deployedTo\":\"\([^\"]*\)\".*/\1/p")
  case "$TICKMATH" in 0x*) ;; *) echo "could not read the TickMath address from forge create" >&2; exit 1 ;; esac
  # Record it, so a re-run links against the same library instead of deploying a second copy.
  sed -i.bak "s|\"tickMath\": \"0x0000000000000000000000000000000000000000\"|\"tickMath\": \"$TICKMATH\"|" \
    "config/$CHAIN.json"
  rm -f "config/$CHAIN.json.bak"
  echo "    TickMath $TICKMATH (written into config/$CHAIN.json)"
else
  echo "==> reusing TickMath $TICKMATH from config/$CHAIN.json"
fi
LIBS="src/libraries/TickMath.sol:TickMath:$TICKMATH"

# ── verification ─────────────────────────────────────────────────────────────
# `forge script --verify` submits every contract it deployed with the constructor arguments it already knows,
# which is exact where a hand-written `forge verify-contract` has to guess. `script/Verify.s.sol` writes the
# re-run commands for later.
VERIFY_ARGS=""
if [ "$VERIFY" = "1" ] && [ "$DRY_RUN" = "0" ]; then
  VERIFIER=$(sed -n 's/^[[:space:]]*"verifier": "\([^"]*\)".*/\1/p' "config/$CHAIN.json")
  VERIFIER_URL=$(sed -n 's/^[[:space:]]*"verifierUrl": "\([^"]*\)".*/\1/p' "config/$CHAIN.json")
  VERIFY_ARGS="--verify --verifier $VERIFIER --verifier-url $VERIFIER_URL --retries 10 --delay 5"
fi

# ── stages 1-4 ───────────────────────────────────────────────────────────────
# `--slow` sends one transaction at a time: constructors assert on contracts deployed moments earlier, and a
# chain with 100 ms blocks will happily reorder a batch of nonces otherwise.
BROADCAST="--broadcast --slow"
if [ "$DRY_RUN" = "1" ]; then
  BROADCAST=""
fi

echo "==> deploying to chain $CHAIN"
# shellcheck disable=SC2086
forge script script/Deploy.s.sol:Deploy --sig "run()" \
  --rpc-url "$RPC" --libraries "$LIBS" $BROADCAST $VERIFY_ARGS "$@"

if [ "$DRY_RUN" = "1" ]; then
  echo "dry run complete: nothing was broadcast."
  exit 0
fi

# ── verification of the result ───────────────────────────────────────────────
# Standalone, against the chain, reading only `config/` and `deployments/`. On a chain with a real timelock
# delay this will fail until both batches have executed, which is the point: it reports how far the handover
# actually got. See docs/RUNBOOK.md.
echo "==> verifying the deployment"
forge script script/Verify.s.sol:Verify --sig "run()" --rpc-url "$RPC" --libraries "$LIBS" -v

echo
echo "Address book: $ROOT/deployments/$CHAIN.json"
