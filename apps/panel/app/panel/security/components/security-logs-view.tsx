"use client";

import { useEffect, useState } from "react";

interface Fail2banStatus {
  jails?: string[];
  banned?: Record<string, string[]>;
  error?: string;
}

interface SecurityLogsData {
  ok: boolean;
  status: Fail2banStatus;
  logs: string[];
}

export function SecurityLogsView() {
  const [data, setData] = useState<SecurityLogsData | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [autoRefresh, setAutoRefresh] = useState(true);

  const fetchLogs = async () => {
    try {
      setLoading(true);
      const res = await fetch("/api/security/logs");
      if (!res.ok) {
        throw new Error("Failed to fetch security logs");
      }
      const data = await res.json();
      setData(data);
      setError(null);
    } catch (err: any) {
      setError(err.message || "Failed to load security logs");
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    fetchLogs();
    
    if (autoRefresh) {
      const interval = setInterval(fetchLogs, 5000); // Refresh every 5 seconds
      return () => clearInterval(interval);
    }
  }, [autoRefresh]);

  if (loading && !data) {
    return (
      <div className="bg-white rounded-lg shadow p-6">
        <p className="text-gray-600">Loading security logs...</p>
      </div>
    );
  }

  if (error) {
    return (
      <div className="bg-white rounded-lg shadow p-6">
        <div className="text-red-600 mb-4">Error: {error}</div>
        <button
          onClick={fetchLogs}
          className="px-4 py-2 bg-blue-600 text-white rounded hover:bg-blue-700"
        >
          Retry
        </button>
      </div>
    );
  }

  const status = data?.status || {};
  const logs = data?.logs || [];

  return (
    <div className="space-y-6">
      {/* Fail2ban Status */}
      <div className="bg-white rounded-lg shadow p-6">
        <div className="flex items-center justify-between mb-4">
          <h2 className="text-lg font-semibold">Fail2ban Status</h2>
          <label className="flex items-center gap-2 text-sm">
            <input
              type="checkbox"
              checked={autoRefresh}
              onChange={(e) => setAutoRefresh(e.target.checked)}
              className="rounded"
            />
            <span>Auto-refresh (5s)</span>
          </label>
        </div>

        {status.error ? (
          <div className="text-red-600 p-4 bg-red-50 rounded">
            <strong>Error:</strong> {status.error}
          </div>
        ) : (
          <div className="space-y-4">
            {status.jails && status.jails.length > 0 ? (
              <>
                <div>
                  <strong className="text-gray-700">Active Jails:</strong>
                  <div className="mt-2 flex flex-wrap gap-2">
                    {status.jails.map((jail) => (
                      <span
                        key={jail}
                        className="px-3 py-1 bg-blue-100 text-blue-800 rounded-full text-sm"
                      >
                        {jail}
                      </span>
                    ))}
                  </div>
                </div>

                {status.banned && Object.keys(status.banned).length > 0 && (
                  <div>
                    <strong className="text-gray-700">Banned IPs:</strong>
                    <div className="mt-2 space-y-2">
                      {Object.entries(status.banned).map(([jail, ips]) => {
                        if (!ips || ips.length === 0) return null;
                        return (
                          <div key={jail} className="border-l-4 border-red-500 pl-4">
                            <div className="font-medium text-gray-800">{jail}:</div>
                            <div className="mt-1 flex flex-wrap gap-2">
                              {ips.map((ip) => (
                                <span
                                  key={ip}
                                  className="px-2 py-1 bg-red-100 text-red-800 rounded text-sm font-mono"
                                >
                                  {ip}
                                </span>
                              ))}
                            </div>
                          </div>
                        );
                      })}
                    </div>
                  </div>
                )}

                {(!status.banned || Object.values(status.banned).every(ips => !ips || ips.length === 0)) && (
                  <div className="text-green-600 p-4 bg-green-50 rounded">
                    ✓ No IPs currently banned
                  </div>
                )}
              </>
            ) : (
              <div className="text-gray-600 p-4 bg-gray-50 rounded">
                No active jails found
              </div>
            )}
          </div>
        )}
      </div>

      {/* Security Logs */}
      <div className="bg-white rounded-lg shadow p-6">
        <div className="flex items-center justify-between mb-4">
          <h2 className="text-lg font-semibold">Security Event Logs</h2>
          <button
            onClick={fetchLogs}
            className="px-4 py-2 bg-gray-600 text-white rounded hover:bg-gray-700 text-sm"
          >
            Refresh
          </button>
        </div>

        <div className="bg-gray-900 text-gray-100 rounded p-4 font-mono text-sm overflow-auto max-h-96">
          {logs.length > 0 ? (
            <pre className="whitespace-pre-wrap">{logs.join("\n")}</pre>
          ) : (
            <div className="text-gray-500">No log entries found</div>
          )}
        </div>
      </div>
    </div>
  );
}
