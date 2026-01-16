import "./globals.css";
import type { ReactNode } from "react";

export const metadata = {
  title: "Voxeil Panel",
  description: "Minimal self-hosted Kubernetes panel"
};

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="en">
      <body>
        {children}
      </body>
    </html>
  );
}
