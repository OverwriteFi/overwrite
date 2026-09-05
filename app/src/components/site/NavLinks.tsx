"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";

export function NavLinks({ stakeEnabled }: { stakeEnabled: boolean }) {
  const path = usePathname();
  const items = [
    { href: "/vaults", label: "Vaults" },
    ...(stakeEnabled ? [{ href: "/stake", label: "Stake" }] : []),
    { href: "/points", label: "Points" },
    { href: "/docs", label: "Docs" },
  ];
  return (
    <ul className="flex items-center gap-5 sm:gap-7 list-none m-0 p-0">
      {items.map((it) => {
        const active = path === it.href || path.startsWith(it.href + "/");
        return (
          <li key={it.href}>
            <Link
              href={it.href}
              aria-current={active ? "page" : undefined}
              className={`no-underline text-[15px] ${active ? "text-ink font-bold" : "text-gray hover:text-ink"}`}
            >
              {it.label}
            </Link>
          </li>
        );
      })}
    </ul>
  );
}
