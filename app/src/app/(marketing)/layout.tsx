import { Footer } from "@/components/site/Footer";
import { MarketingHeader } from "@/components/landing/MarketingHeader";
import "./landing.css";

/** The marketing home at `/`: no wallet, no wagmi. Styles are the landing's own, scoped under `.landing`. */
export default function MarketingLayout({ children }: LayoutProps<"/">) {
  return (
    <div className="landing flex-1 flex flex-col">
      <MarketingHeader />
      <main className="flex-1">{children}</main>
      <Footer />
    </div>
  );
}
