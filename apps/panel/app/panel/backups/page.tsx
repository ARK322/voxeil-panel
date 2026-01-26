import { api } from "../../../src/lib/api";

export const dynamic = "force-dynamic";

async function BackupsPage() {
  const backups = await api.backups.get();

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold text-gray-900">Backups</h1>
          <p className="text-gray-600 mt-1">Manage backup snapshots and schedules</p>
        </div>
        <button className="px-4 py-2 bg-green-600 text-white rounded-lg hover:bg-green-700">
          Run Backup Now
        </button>
      </div>

      <div className="bg-white rounded-lg shadow p-6">
        <h2 className="text-lg font-semibold mb-4">Backup Status</h2>
        <div className="space-y-2 mb-6">
          <p className="text-sm text-gray-600">
            Status:{" "}
            <span
              className={`px-2 py-1 rounded text-xs ${
                backups.status === "enabled"
                  ? "bg-green-100 text-green-800"
                  : "bg-gray-100 text-gray-800"
              }`}
            >
              {backups.status}
            </span>
          </p>
          {backups.lastBackupAt && (
            <p className="text-sm text-gray-600">
              Last backup: {new Date(backups.lastBackupAt).toLocaleString()}
            </p>
          )}
        </div>

        <h3 className="font-semibold mb-4">Snapshots</h3>
        <div className="space-y-3">
          {backups.snapshots.map((snapshot) => (
            <div
              key={snapshot.id}
              className="flex items-center justify-between p-4 border border-gray-200 rounded-lg"
            >
              <div>
                <p className="font-mono text-sm">{snapshot.id}</p>
                <p className="text-xs text-gray-500 mt-1">
                  {new Date(snapshot.timestamp).toLocaleString()}
                </p>
              </div>
              <div className="flex items-center gap-4">
                <span className="text-sm text-gray-600">
                  {(snapshot.sizeBytes / 1024 / 1024).toFixed(2)} MB
                </span>
                <span
                  className={`px-3 py-1 rounded-full text-xs ${
                    snapshot.type === "full"
                      ? "bg-blue-100 text-blue-800"
                      : "bg-gray-100 text-gray-800"
                  }`}
                >
                  {snapshot.type}
                </span>
                <button className="text-sm text-blue-600 hover:text-blue-800">Restore</button>
              </div>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}

export default BackupsPage;
