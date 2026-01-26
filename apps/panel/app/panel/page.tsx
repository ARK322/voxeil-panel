import Link from "next/link";
import { api } from "../../src/lib/api";

async function DashboardPage() {
  const health = await api.health.get();
  const tenants = await api.tenants.list();
  const sites = await api.sites.list();
  const mail = await api.mail.get();
  const db = await api.db.get();
  const backups = await api.backups.get();

  const stats = [
    {
      label: "Tenants",
      value: tenants.length,
      href: "/panel/users",
      icon: "👥",
      color: "bg-blue-500",
    },
    {
      label: "Web Sites",
      value: sites.length,
      href: "/panel/web",
      icon: "🌐",
      color: "bg-green-500",
    },
    {
      label: "Mail Domains",
      value: mail.domains.length,
      href: "/panel/mail",
      icon: "✉️",
      color: "bg-purple-500",
    },
    {
      label: "Databases",
      value: db.instances.length,
      href: "/panel/db",
      icon: "💾",
      color: "bg-yellow-500",
    },
    {
      label: "DNS Zones",
      value: 1, // Mock
      href: "/panel/dns",
      icon: "🔗",
      color: "bg-indigo-500",
    },
    {
      label: "Backups",
      value: backups.snapshots.length,
      href: "/panel/backups",
      icon: "💿",
      color: "bg-red-500",
    },
  ];

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-bold text-gray-900">Dashboard</h1>
        <p className="text-gray-600 mt-1">Overview of your hosting platform</p>
      </div>

      {/* Health Status */}
      <div className="bg-white rounded-lg shadow p-6">
        <h2 className="text-lg font-semibold mb-4">System Health</h2>
        <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
          {Object.entries(health.components).map(([component, status]) => (
            <div key={component} className="flex items-center gap-2">
              <div
                className={`w-3 h-3 rounded-full ${
                  status === "healthy" ? "bg-green-500" : "bg-red-500"
                }`}
              />
              <span className="text-sm capitalize">{component}</span>
            </div>
          ))}
        </div>
      </div>

      {/* Stats Cards */}
      <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
        {stats.map((stat) => (
          <Link
            key={stat.label}
            href={stat.href}
            className="bg-white rounded-lg shadow p-6 hover:shadow-lg transition-shadow"
          >
            <div className="flex items-center justify-between">
              <div>
                <p className="text-sm text-gray-600">{stat.label}</p>
                <p className="text-3xl font-bold text-gray-900 mt-2">{stat.value}</p>
              </div>
              <div className={`${stat.color} w-12 h-12 rounded-lg flex items-center justify-center text-2xl`}>
                {stat.icon}
              </div>
            </div>
          </Link>
        ))}
      </div>

      {/* Quick Actions */}
      <div className="bg-white rounded-lg shadow p-6">
        <h2 className="text-lg font-semibold mb-4">Quick Actions</h2>
        <div className="flex flex-wrap gap-3">
          <button className="px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700">
            Create Site
          </button>
          <button className="px-4 py-2 bg-green-600 text-white rounded-lg hover:bg-green-700">
            Run Backup Now
          </button>
          <button className="px-4 py-2 bg-purple-600 text-white rounded-lg hover:bg-purple-700">
            Provision Tenant
          </button>
        </div>
      </div>
    </div>
  );
}

export default DashboardPage;
