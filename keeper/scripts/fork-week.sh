#!/usr/bin/env bash
# One full simulated week against a local anvil fork of 46630.
#
#   ./scripts/fork-week.sh                 # fork at head
#   FORK_BLOCK=113080000 ./scripts/fork-week.sh   # pin the fork block for a reproducible run
#
# On the ~19-minute clock. The public testnet RPC is not an archive node: it keeps roughly 9 000 blocks
# of historical state, and at the ~8 blocks/s this chain produces that is about 19 minutes. Anvil pins
# the fork block at startup and fetches state from it lazily, so any slot first touched after the
# upstream node has pruned that block fails with "metadata is not found".
#
# The fix is not a state snapshot — `anvil_dumpState` serialises only anvil's own locally-modified
# accounts, not the forked state it has cached, so a dump taken after forking is empty. What does work
# is anvil's in-process cache: every slot it has already fetched is served locally for the life of the
# process. So this script forks once, immediately walks every account, feed round and pool observation
# the week will touch (test/week/prefetch.ts), and only then starts the run. The whole thing takes a
# couple of minutes inside a nineteen-minute budget, and after the prefetch it needs no upstream reads
# at all.
set -euo pipefail

cd "$(dirname "$0")/.."
FOUNDRY_BIN="${FOUNDRY_BIN:-$HOME/.foundry/bin}"
export PATH="$FOUNDRY_BIN:$PATH"
RPC="${ROBINHOOD_TESTNET_RPC_URL:-https://rpc.testnet.chain.robinhood.com}"
PORT="${ANVIL_PORT:-8545}"
export ANVIL_URL="http://127.0.0.1:${PORT}"
LOG="${WEEK_LOG:-state/week.log}"

command -v anvil >/dev/null || { echo "anvil not on PATH (looked in $FOUNDRY_BIN)"; exit 1; }
mkdir -p state

cleanup() { [ -n "${ANVIL_PID:-}" ] && kill "$ANVIL_PID" 2>/dev/null || true; }
trap cleanup EXIT

FORK_ARGS=(--fork-url "$RPC")
[ -n "${FORK_BLOCK:-}" ] && FORK_ARGS+=(--fork-block-number "$FORK_BLOCK")

echo "forking $RPC${FORK_BLOCK:+ at block $FORK_BLOCK} ..."
anvil "${FORK_ARGS[@]}" --port "$PORT" --host 127.0.0.1 --silent &
ANVIL_PID=$!

for _ in $(seq 1 60); do
  curl -s -m 2 -X POST -H 'content-type: application/json' \
    --data '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}' "$ANVIL_URL" >/dev/null 2>&1 && break
  sleep 0.5
done

echo "warming the fork cache before the upstream node prunes the fork block ..."
node --import tsx test/week/prefetch.ts

node --import tsx test/week/simulate-week.ts 2>&1 | tee "$LOG"
echo
echo "log written to $(pwd)/$LOG"
