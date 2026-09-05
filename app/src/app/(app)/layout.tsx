import { headers } from "next/headers";
import { cookieToInitialState } from "wagmi";
import { getConfig } from "@/lib/wagmi";
import { Providers } from "../providers";
import { Header } from "@/components/site/Header";
import { Footer } from "@/components/site/Footer";

/** The wallet-connected part of the site: /vaults, /stake, /points, /docs. */
export default async function AppLayout({ children }: LayoutProps<"/">) {
  const initialState = cookieToInitialState(getConfig(), (await headers()).get("cookie"));
  return (
    <Providers initialState={initialState}>
      <Header />
      <main className="flex-1">{children}</main>
      <Footer />
    </Providers>
  );
}
