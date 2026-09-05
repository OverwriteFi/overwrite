"use client";

import { useMemo } from "react";
import type { Address } from "viem";
import { useReadContracts } from "wagmi";
import { erc20Abi, stockTokenAbi, vaultAbi } from "@/lib/abi";
import { targetChain } from "@/lib/chains";
import { deployment } from "@/lib/deployment";
import { useTargetChain } from "./useTargetChain";

export interface VaultUserState {
  ready: boolean;
  loading: boolean;
  error: Error | null;
  address: Address | undefined;
  stockBalance: bigint;
  stockAllowance: bigint;
  usdgBalance: bigint;
  shares: bigint;
  /** Stock tokens the shares are worth, 18 dp (via assetsPerShare from the server snapshot). */
  positionAssets: bigint;
  maxDeposit: bigint;
  maxWithdraw: bigint;
  maxRedeem: bigint;
  premiumClaimable: bigint;
  withdrawalClaimable: bigint;
  uiMultiplier: bigint;
  refetch: () => void;
}

export function useVaultUser(
  vault: Address,
  stock: Address,
  assetsPerShare: string,
): VaultUserState {
  const { address, ready } = useTargetChain();
  const usdg = deployment.external.usdg;
  const enabled = ready && !!address;

  const q = useReadContracts({
    allowFailure: true,
    query: { enabled },
    contracts: address
      ? [
          { address: stock, abi: stockTokenAbi, functionName: "balanceOf", args: [address], chainId: targetChain.id },
          { address: stock, abi: stockTokenAbi, functionName: "allowance", args: [address, vault], chainId: targetChain.id },
          { address: usdg, abi: erc20Abi, functionName: "balanceOf", args: [address], chainId: targetChain.id },
          { address: vault, abi: vaultAbi, functionName: "balanceOf", args: [address], chainId: targetChain.id },
          { address: vault, abi: vaultAbi, functionName: "maxDeposit", args: [address], chainId: targetChain.id },
          { address: vault, abi: vaultAbi, functionName: "maxWithdraw", args: [address], chainId: targetChain.id },
          { address: vault, abi: vaultAbi, functionName: "maxRedeem", args: [address], chainId: targetChain.id },
          { address: vault, abi: vaultAbi, functionName: "premiumClaimable", args: [address], chainId: targetChain.id },
          { address: vault, abi: vaultAbi, functionName: "withdrawalClaimable", args: [address], chainId: targetChain.id },
          { address: stock, abi: stockTokenAbi, functionName: "uiMultiplier", chainId: targetChain.id },
        ]
      : [],
  });

  return useMemo(() => {
    const g = (i: number): bigint => {
      const r = q.data?.[i];
      return r && r.status === "success" ? (r.result as bigint) : 0n;
    };
    const shares = g(3);
    const aps = BigInt(assetsPerShare || "0");
    return {
      ready: enabled,
      loading: enabled && q.isLoading,
      error: (q.error as Error | null) ?? null,
      address,
      stockBalance: g(0),
      stockAllowance: g(1),
      usdgBalance: g(2),
      shares,
      positionAssets: (shares * aps) / 10n ** 24n,
      maxDeposit: g(4),
      maxWithdraw: g(5),
      maxRedeem: g(6),
      premiumClaimable: g(7),
      withdrawalClaimable: g(8),
      uiMultiplier: q.data?.[9]?.status === "success" ? (q.data[9].result as bigint) : 10n ** 18n,
      refetch: () => void q.refetch(),
    };
  }, [q, address, enabled, assetsPerShare]);
}
