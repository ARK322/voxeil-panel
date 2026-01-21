import "../globals.css";
import { Sidebar } from "./components/sidebar";
import { TopBar } from "./components/topbar";

export const metadata = {
  title: "Voxeil Panel",
  description: "Kubernetes hosting control panel",
};

export default function PanelLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en">
      <body className="bg-gray-50">
        <div className="flex h-screen overflow-hidden">
          <Sidebar />
          <div className="flex flex-1 flex-col overflow-hidden">
            <TopBar />
            <main className="flex-1 overflow-y-auto p-6">{children}</main>
          </div>
        </div>
      </body>
    </html>
  );
}
