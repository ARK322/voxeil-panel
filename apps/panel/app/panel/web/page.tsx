import Link from "next/link";
import { api } from "../../src/lib/api";

async function WebSitesPage() {
  const sites = await api.sites.list();

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold text-gray-900">Web Sites</h1>
          <p className="text-gray-600 mt-1">Manage your web applications</p>
        </div>
        <button className="px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700">
          + Create Site
        </button>
      </div>

      <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
        {sites.map((site) => (
          <Link
            key={site.id}
            href={`/panel/web/${site.id}`}
            className="bg-white rounded-lg shadow p-6 hover:shadow-lg transition-shadow"
          >
            <div className="flex items-start justify-between mb-4">
              <div>
                <h3 className="font-semibold text-gray-900">{site.name}</h3>
                <p className="text-sm text-gray-500 mt-1">{site.slug}</p>
              </div>
              <span
                className={`px-2 py-1 rounded text-xs ${
                  site.status === "deployed"
                    ? "bg-green-100 text-green-800"
                    : "bg-yellow-100 text-yellow-800"
                }`}
              >
                {site.status}
              </span>
            </div>
            <div className="space-y-2">
              <div className="flex items-center gap-2">
                <span className="text-sm text-gray-600">Domain:</span>
                <span className="text-sm font-mono">{site.primaryDomain}</span>
              </div>
              <div className="flex items-center gap-2">
                <span className="text-sm text-gray-600">TLS:</span>
                <span className="text-sm">
                  {site.tls.enabled ? "✅ Enabled" : "❌ Disabled"}
                </span>
              </div>
              {site.lastDeployAt && (
                <div className="flex items-center gap-2">
                  <span className="text-sm text-gray-600">Last deploy:</span>
                  <span className="text-sm">
                    {new Date(site.lastDeployAt).toLocaleDateString()}
                  </span>
                </div>
              )}
            </div>
          </Link>
        ))}
      </div>
    </div>
  );
}

export default WebSitesPage;
