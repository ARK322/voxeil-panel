import { api } from "../../../../src/lib/api";
import Link from "next/link";

async function SiteDetailPage({ params }: { params: { siteId: string } }) {
  const site = await api.sites.get(params.siteId);

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <div>
          <Link href="/panel/web" className="text-sm text-blue-600 hover:text-blue-800 mb-2 inline-block">
            ← Back to Sites
          </Link>
          <h1 className="text-2xl font-bold text-gray-900">{site.name}</h1>
          <p className="text-gray-600 mt-1">{site.primaryDomain}</p>
        </div>
        <button className="px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700">
          Deploy
        </button>
      </div>

      {/* Domains */}
      <div className="bg-white rounded-lg shadow p-6">
        <h2 className="text-lg font-semibold mb-4">Domains</h2>
        <div className="space-y-2">
          {site.domains.map((domain) => (
            <div key={domain} className="flex items-center justify-between p-3 bg-gray-50 rounded">
              <span className="font-mono">{domain}</span>
              <button className="text-sm text-blue-600 hover:text-blue-800">Copy</button>
            </div>
          ))}
        </div>
      </div>

      {/* TLS */}
      <div className="bg-white rounded-lg shadow p-6">
        <h2 className="text-lg font-semibold mb-4">TLS Certificate</h2>
        <div className="space-y-2">
          <p className="text-sm text-gray-600">
            Status: {site.tls.enabled ? "✅ Enabled" : "❌ Disabled"}
          </p>
          {site.tls.issuer && (
            <p className="text-sm text-gray-600">Issuer: {site.tls.issuer}</p>
          )}
        </div>
      </div>

      {/* Environment Variables */}
      <div className="bg-white rounded-lg shadow p-6">
        <h2 className="text-lg font-semibold mb-4">Environment Variables</h2>
        <div className="space-y-2">
          {site.env.map((envVar) => (
            <div key={envVar.key} className="flex items-center justify-between p-3 bg-gray-50 rounded">
              <div>
                <span className="font-mono text-sm">{envVar.key}</span>
                <span className="text-sm text-gray-500 ml-2">
                  = {envVar.isSecret ? "***" : envVar.value}
                </span>
              </div>
            </div>
          ))}
        </div>
      </div>

      {/* Deploy History */}
      <div className="bg-white rounded-lg shadow p-6">
        <h2 className="text-lg font-semibold mb-4">Deploy History</h2>
        <div className="space-y-3">
          {site.deployHistory.map((deploy) => (
            <div
              key={deploy.id}
              className="flex items-center justify-between p-4 border border-gray-200 rounded-lg"
            >
              <div>
                <p className="font-mono text-sm">{deploy.image}</p>
                <p className="text-xs text-gray-500 mt-1">
                  {new Date(deploy.timestamp).toLocaleString()}
                </p>
              </div>
              <span
                className={`px-3 py-1 rounded-full text-xs ${
                  deploy.status === "success"
                    ? "bg-green-100 text-green-800"
                    : "bg-red-100 text-red-800"
                }`}
              >
                {deploy.status}
              </span>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}

export default SiteDetailPage;
