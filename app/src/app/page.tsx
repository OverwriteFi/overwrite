import { WalletButton } from "@/components/wallet-button";
import { targetChain } from "@/lib/chains";

export default function Home() {
  return (
    <main className="flex flex-1 flex-col items-center justify-center gap-6 p-8">
      <h1 className="text-3xl font-semibold tracking-tight">overwrite</h1>
      <p className="text-sm opacity-70">
        {targetChain.name} · chainId {targetChain.id} · gas in ETH
      </p>
      <WalletButton />
    </main>
  );
}
