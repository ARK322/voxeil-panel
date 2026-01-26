import { api } from "../../../src/lib/api";
import { env } from "../../../src/lib/env";

async function MailPage() {
  const mail = await api.mail.get();

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold text-gray-900">Mail</h1>
          <p className="text-gray-600 mt-1">Manage email domains and mailboxes</p>
        </div>
        {mail.status === "enabled" && env.MAIL_UI_URL && (
          <a
            href={env.MAIL_UI_URL}
            target="_blank"
            rel="noopener noreferrer"
            className="px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700"
          >
            Open Mailcow UI →
          </a>
        )}
      </div>

      {mail.status === "enabled" && env.MAIL_UI_URL && (
        <div className="bg-yellow-50 border border-yellow-200 rounded-lg p-4">
          <p className="text-sm text-yellow-800">
            ⚠️ <strong>Admin-only:</strong> External link to mailcow interface. Opens in new tab.
          </p>
        </div>
      )}

      <div className="bg-white rounded-lg shadow p-6">
        <h2 className="text-lg font-semibold mb-4">Mail Domains</h2>
        <div className="space-y-4">
          {mail.domains.map((domain) => (
            <div key={domain.domain} className="border border-gray-200 rounded-lg p-4">
              <div className="flex items-center justify-between mb-2">
                <h3 className="font-semibold">{domain.domain}</h3>
                <span className="px-2 py-1 bg-green-100 text-green-800 rounded text-xs">
                  Active
                </span>
              </div>
              <div className="flex gap-6 text-sm text-gray-600">
                <span>Mailboxes: {domain.mailboxesCount}</span>
                <span>Aliases: {domain.aliasesCount}</span>
              </div>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}

export default MailPage;
