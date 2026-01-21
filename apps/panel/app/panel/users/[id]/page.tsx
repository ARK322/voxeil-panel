import { api } from "../../../../src/lib/api";
import Link from "next/link";

async function TenantDetailPage({ params }: { params: { id: string } }) {
  const tenant = await api.tenants.get(params.id);

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <div>
          <Link href="/panel/users" className="text-sm text-blue-600 hover:text-blue-800 mb-2 inline-block">
            ← Back to Users
          </Link>
          <h1 className="text-2xl font-bold text-gray-900">{tenant.name}</h1>
          <p className="text-gray-600 mt-1">Namespace: {tenant.namespaces[0]}</p>
        </div>
      </div>

      {/* Quotas */}
      <div className="bg-white rounded-lg shadow p-6">
        <h2 className="text-lg font-semibold mb-4">Resource Quotas</h2>
        <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
          <div>
            <p className="text-sm text-gray-600">CPU</p>
            <p className="text-xl font-semibold">
              {tenant.quotas.cpu.request} / {tenant.quotas.cpu.limit}
            </p>
          </div>
          <div>
            <p className="text-sm text-gray-600">Memory</p>
            <p className="text-xl font-semibold">
              {tenant.quotas.memory.request} / {tenant.quotas.memory.limit}
            </p>
          </div>
          <div>
            <p className="text-sm text-gray-600">Storage</p>
            <p className="text-xl font-semibold">{tenant.quotas.storage.limit}</p>
          </div>
        </div>
      </div>

      {/* Sites */}
      <div className="bg-white rounded-lg shadow p-6">
        <h2 className="text-lg font-semibold mb-4">Sites ({tenant.sites.length})</h2>
        <div className="space-y-3">
          {tenant.sites.map((site) => (
            <div
              key={site.id}
              className="flex items-center justify-between p-4 border border-gray-200 rounded-lg"
            >
              <div>
                <Link
                  href={`/panel/web/${site.id}`}
                  className="font-medium text-blue-600 hover:text-blue-800"
                >
                  {site.name}
                </Link>
                <p className="text-sm text-gray-600">{site.primaryDomain}</p>
              </div>
              <span
                className={`px-3 py-1 rounded-full text-xs ${
                  site.status === "deployed"
                    ? "bg-green-100 text-green-800"
                    : "bg-yellow-100 text-yellow-800"
                }`}
              >
                {site.status}
              </span>
            </div>
          ))}
        </div>
      </div>

      {/* Mail */}
      <div className="bg-white rounded-lg shadow p-6">
        <h2 className="text-lg font-semibold mb-4">Mail</h2>
        <div className="space-y-2">
          <p className="text-sm text-gray-600">Domains: {tenant.mail.domains.join(", ") || "None"}</p>
          <p className="text-sm text-gray-600">Mailboxes: {tenant.mail.mailboxesCount}</p>
        </div>
      </div>

      {/* Database */}
      <div className="bg-white rounded-lg shadow p-6">
        <h2 className="text-lg font-semibold mb-4">Database</h2>
        <p className="text-sm text-gray-600">Databases: {tenant.db.databasesCount}</p>
      </div>
    </div>
  );
}

export default TenantDetailPage;
