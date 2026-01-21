import { api } from "../../src/lib/api";

async function DnsPage() {
  const dns = await api.dns.get();

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-bold text-gray-900">DNS</h1>
        <p className="text-gray-600 mt-1">Manage DNS zones and records</p>
      </div>

      <div className="bg-white rounded-lg shadow p-6">
        <h2 className="text-lg font-semibold mb-4">DNS Zones</h2>
        <div className="space-y-4">
          {dns.zones.map((zone) => (
            <div key={zone.domain} className="border border-gray-200 rounded-lg p-4">
              <div className="flex items-center justify-between mb-2">
                <h3 className="font-semibold">{zone.domain}</h3>
                <span className="px-2 py-1 bg-green-100 text-green-800 rounded text-xs">
                  Active
                </span>
              </div>
              <p className="text-sm text-gray-600">Records: {zone.recordsCount}</p>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}

export default DnsPage;
