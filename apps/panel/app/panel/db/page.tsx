import { api } from "../../../src/lib/api";
import { env } from "../../../src/lib/env";

async function DbPage() {
  const db = await api.db.get();

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold text-gray-900">Database</h1>
          <p className="text-gray-600 mt-1">Manage PostgreSQL databases</p>
        </div>
        {db.status === "enabled" && env.PGADMIN_URL && (
          <a
            href={env.PGADMIN_URL}
            target="_blank"
            rel="noopener noreferrer"
            className="px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700"
          >
            Open pgAdmin →
          </a>
        )}
      </div>

      {db.status === "enabled" && env.PGADMIN_URL && (
        <div className="bg-yellow-50 border border-yellow-200 rounded-lg p-4">
          <p className="text-sm text-yellow-800">
            ⚠️ <strong>Admin-only:</strong> External link to pgAdmin interface. Opens in new tab.
          </p>
        </div>
      )}

      <div className="bg-white rounded-lg shadow p-6">
        <h2 className="text-lg font-semibold mb-4">Database Instances</h2>
        <div className="space-y-4">
          {db.instances.map((instance) => (
            <div key={instance.id} className="border border-gray-200 rounded-lg p-4">
              <div className="flex items-center justify-between mb-2">
                <h3 className="font-semibold">{instance.name}</h3>
                <span className="px-2 py-1 bg-green-100 text-green-800 rounded text-xs">
                  Active
                </span>
              </div>
              <div className="flex gap-6 text-sm text-gray-600">
                <span>Host: {instance.host}</span>
                <span>Port: {instance.port}</span>
              </div>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}

export default DbPage;
