import Link from "next/link";
import { Empty } from "@/components/site/States";
import { vaults } from "@/lib/deployment";

export default function VaultNotFound() {
  return (
    <div className="wrap pt-10 sm:pt-14">
      <Empty
        title="No vault by that name."
        action={
          <Link href="/vaults" className="btn btn-blue btn-sm">
            See all vaults
          </Link>
        }
      >
        Vaults on this deployment: {vaults.map((v) => v.symbol).join(", ") || "none yet"}.
      </Empty>
    </div>
  );
}
