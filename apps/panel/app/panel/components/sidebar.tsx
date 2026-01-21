"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";

const navItems = [
  { href: "/panel", label: "Dashboard", icon: "📊" },
  { href: "/panel/users", label: "Users", icon: "👥" },
  { href: "/panel/web", label: "Web Sites", icon: "🌐" },
  { href: "/panel/mail", label: "Mail", icon: "✉️" },
  { href: "/panel/db", label: "Database", icon: "💾" },
  { href: "/panel/dns", label: "DNS", icon: "🔗" },
  { href: "/panel/backups", label: "Backups", icon: "💿" },
  { href: "/panel/health", label: "Health", icon: "❤️" },
];

export function Sidebar() {
  const pathname = usePathname();

  return (
    <aside className="w-64 bg-gray-900 text-white flex flex-col">
      <div className="p-4 border-b border-gray-800">
        <h1 className="text-xl font-bold">Voxeil Panel</h1>
        <p className="text-xs text-gray-400 mt-1">Hosting Control</p>
      </div>
      <nav className="flex-1 p-4 space-y-1">
        {navItems.map((item) => {
          const isActive = pathname === item.href || pathname?.startsWith(item.href + "/");
          return (
            <Link
              key={item.href}
              href={item.href}
              className={`flex items-center gap-3 px-4 py-2 rounded-lg transition-colors ${
                isActive
                  ? "bg-blue-600 text-white"
                  : "text-gray-300 hover:bg-gray-800 hover:text-white"
              }`}
            >
              <span className="text-lg">{item.icon}</span>
              <span>{item.label}</span>
            </Link>
          );
        })}
      </nav>
      <div className="p-4 border-t border-gray-800 text-xs text-gray-400">
        <p>v1.0.0</p>
      </div>
    </aside>
  );
}
