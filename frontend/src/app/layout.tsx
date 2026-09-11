import type { Metadata } from "next";
import type { ReactNode } from "react";
import { AppShell } from "@/components/shell";
import "./globals.css";
import { Providers } from "./providers";

export const metadata: Metadata = {
  title: "Risk-Aware Lending Protocol",
  description: "A risk-aware DeFi lending protocol: supply, borrow, liquidations, oracle circuit breakers and live risk monitoring. Local demo with mock assets only.",
};

// Applies the stored theme before first paint, so there is no light/dark flash.
const themeScript = `try{var t=localStorage.getItem("theme");if(t==="light"||t==="dark")document.documentElement.setAttribute("data-theme",t)}catch(e){}`;

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="en" data-theme="dark" suppressHydrationWarning>
      <head>
        <script dangerouslySetInnerHTML={{ __html: themeScript }} />
      </head>
      <body>
        <Providers>
          <AppShell>{children}</AppShell>
        </Providers>
      </body>
    </html>
  );
}
