import { api } from "../../../src/lib/api";

function StatusBadge({ status }: { status: string }) {
  const colors =
    status === "healthy"
      ? "bg-green-100 text-green-800"
      : status === "degraded"
      ? "bg-yellow-100 text-yellow-800"
      : "bg-red-100 text-red-800";

  return (
    <span className={`px-3 py-1 rounded-full text-xs font-medium ${colors}`}>
      {status.toUpperCase()}
    </span>
  );
}

async function HealthPage() {
  const health = await api.health.get();

  const components = [
    { name: "Controller", status: health.components.controller },
    { name: "PostgreSQL", status: health.components.postgres },
    { name: "Traefik", status: health.components.traefik },
    { name: "cert-manager", status: health.components.certManager },
  ];

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-bold text-gray-900">System Health</h1>
        <p className="text-gray-600 mt-1">Monitor platform component status</p>
      </div>

      <div className="bg-white rounded-lg shadow p-6">
        <div className="flex items-center justify-between mb-6">
          <h2 className="text-lg font-semibold">Overall Status</h2>
          <StatusBadge status={health.status} />
        </div>

        <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
          {components.map((component) => (
            <div
              key={component.name}
              className="flex items-center justify-between p-4 border border-gray-200 rounded-lg"
            >
              <span className="font-medium">{component.name}</span>
              <StatusBadge status={component.status} />
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}

export default HealthPage;
