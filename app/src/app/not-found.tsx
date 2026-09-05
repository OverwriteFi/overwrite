import Link from "next/link";
import { Empty } from "@/components/site/States";

export default function NotFound() {
  return (
    <div className="wrap pt-12 sm:pt-16">
      <Empty
        title="There is nothing here."
        action={
          <Link href="/vaults" className="btn btn-blue btn-sm">
            See the vaults
          </Link>
        }
      >
        The page you asked for does not exist on this deployment.
      </Empty>
    </div>
  );
}
