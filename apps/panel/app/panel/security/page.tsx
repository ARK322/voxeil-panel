import { requireSession } from "@/app/lib/session";
import { SecurityLogsView } from "./components/security-logs-view";

export const dynamic = "force-dynamic";

export default async function SecurityPage() {
  await requireSession();

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-bold text-gray-900">Security Logs</h1>
        <p className="text-gray-600 mt-1">Fail2ban status and security event logs</p>
      </div>

      <SecurityLogsView />
    </div>
  );
}
