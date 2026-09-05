"use client";

import { useRouter } from "next/navigation";
import { vaultAbi } from "@/lib/abi";
import { fmtTokens, fmtUsd } from "@/lib/format";
import type { VaultSnapshotDto } from "@/lib/reads/types";
import { useTx } from "@/hooks/useTx";
import { useVaultUser } from "@/hooks/useVaultUser";
import { useTargetChain } from "@/hooks/useTargetChain";
import { SharesEq } from "@/components/wallet/SharesEq";
import { Row, Rows } from "@/components/site/Bits";
import { TxNote } from "./TxNote";

export function Position({ v }: { v: VaultSnapshotDto }) {
  const { address, mounted, isConnected } = useTargetChain();
  const u = useVaultUser(v.addresses.vault, v.addresses.stock, v.assetsPerShare);
  const premium = useTx();
  const claim = useTx();
  const router = useRouter();

  if (!mounted) return null;
  if (!isConnected || !address) {
    return (
      <p className="text-gray">Connect a wallet to see your position, premium and anything waiting to be claimed.</p>
    );
  }
  if (u.error) {
    return <p className="note text-ink">Could not read your position: {u.error.message}</p>;
  }

  const usdValue =
    v.sRef && u.positionAssets > 0n ? (u.positionAssets * BigInt(v.sRef)) / 10n ** 20n : null;

  return (
    <div>
      <Rows>
        <Row label="Your deposit, in Stock Tokens" note={<SharesEq raw={u.positionAssets} uiMultiplier={u.uiMultiplier} />}>
          {u.loading ? "…" : `${fmtTokens(u.positionAssets)} ${v.symbol}`}
          {usdValue !== null ? <span className="k font-normal">{fmtUsd(usdValue)}</span> : null}
        </Row>
        <Row label="Vault shares" note="Shares are your claim on the vault's tokens. Their token value only changes at settlement.">
          {u.loading ? "…" : fmtTokens(u.shares, 24, 4)}
        </Row>
        <Row label="In your wallet" note={<SharesEq raw={u.stockBalance} uiMultiplier={u.uiMultiplier} />}>
          {u.loading ? "…" : `${fmtTokens(u.stockBalance)} ${v.symbol}`}
          <span className="k font-normal">{fmtUsd(u.usdgBalance, v.usdg.decimals)} {v.usdg.symbol}</span>
        </Row>
        <Row label="Premium waiting for you" note="Paid in USDG the moment an auction clears. Claim any time; it keeps accruing until you do.">
          <span className="pct">{u.loading ? "…" : fmtUsd(u.premiumClaimable, v.usdg.decimals)}</span>
        </Row>
        {u.withdrawalClaimable > 0n ? (
          <Row label="Withdrawal ready to claim" note={<SharesEq raw={u.withdrawalClaimable} uiMultiplier={u.uiMultiplier} />}>
            {fmtTokens(u.withdrawalClaimable)} {v.symbol}
          </Row>
        ) : null}
      </Rows>
      <div className="mt-4 flex flex-wrap gap-3">
        <button
          type="button"
          className="btn btn-blue btn-sm"
          disabled={u.premiumClaimable === 0n || premium.busy}
          onClick={async () => {
            const r = await premium.send({
              address: v.addresses.vault,
              abi: vaultAbi,
              functionName: "claimPremium",
              args: [address],
            });
            if (r) {
              u.refetch();
              router.refresh();
            }
          }}
        >
          {premium.busy ? "Claiming…" : "Claim premium"}
        </button>
        {u.withdrawalClaimable > 0n ? (
          <button
            type="button"
            className="btn btn-plain btn-sm"
            disabled={claim.busy}
            onClick={async () => {
              const r = await claim.send({
                address: v.addresses.vault,
                abi: vaultAbi,
                functionName: "claimWithdrawal",
                args: [address],
              });
              if (r) {
                u.refetch();
                router.refresh();
              }
            }}
          >
            {claim.busy ? "Claiming…" : `Claim ${fmtTokens(u.withdrawalClaimable)} ${v.symbol}`}
          </button>
        ) : null}
      </div>
      <TxNote status={premium.status} hash={premium.hash} error={premium.error} successText="Premium claimed." />
      <TxNote status={claim.status} hash={claim.hash} error={claim.error} successText="Tokens are back in your wallet." />
    </div>
  );
}
