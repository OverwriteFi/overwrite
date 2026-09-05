import { Loading } from "@/components/site/States";

export default function VaultsLoading() {
  return (
    <div className="wrap pt-12 sm:pt-16">
      <h1 className="h1">Make your Stock Tokens pay you every week.</h1>
      <div className="mt-10">
        <Loading label="Reading the vaults…" />
      </div>
    </div>
  );
}
