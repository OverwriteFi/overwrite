import { Loading } from "@/components/site/States";

export default function VaultLoading() {
  return (
    <div className="wrap pt-10 sm:pt-14">
      <Loading label="Reading the vault…" />
    </div>
  );
}
