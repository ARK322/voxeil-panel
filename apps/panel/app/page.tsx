import { createSiteAction, deleteSiteAction, logoutAction } from "./actions";
import { listSites } from "./lib/controller.js";
import { requireSession } from "./lib/session.js";

export default async function HomePage() {
  await requireSession();
  const sites = await listSites();

  return (
    <main>
      <header style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
        <div>
          <h1 style={{ margin: 0 }}>Sites</h1>
          <p style={{ margin: 0, color: "#475569" }}>One tenant = one namespace.</p>
        </div>
        <form action={logoutAction}>
          <button type="submit">Logout</button>
        </form>
      </header>

      <section style={{ marginTop: 24 }}>
        <h2>Create site</h2>
        <form action={createSiteAction} style={{ display: "grid", gap: 12, maxWidth: 420 }}>
          <label style={{ display: "grid", gap: 6 }}>
            <span>Site ID (lowercase, a-z0-9-)</span>
            <input name="siteId" minLength={3} maxLength={40} pattern="[a-z0-9-]+" required />
          </label>
          <label style={{ display: "grid", gap: 6 }}>
            <span>Image (registry/user:tag)</span>
            <input name="image" required />
          </label>
          <label style={{ display: "grid", gap: 6 }}>
            <span>Container port</span>
            <input name="containerPort" type="number" defaultValue={3000} min={1} required />
          </label>
          <button type="submit" style={{ padding: "10px 16px" }}>Create</button>
        </form>
      </section>

      <section style={{ marginTop: 32 }}>
        <h2>Existing sites</h2>
        {sites.length === 0 ? (
          <p>No sites yet.</p>
        ) : (
          <ul style={{ listStyle: "none", padding: 0, display: "grid", gap: 12 }}>
            {sites.map(site => (
              <li key={site.namespace} style={{ border: "1px solid #e2e8f0", borderRadius: 8, padding: 12 }}>
                <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
                  <div>
                    <div style={{ fontWeight: 600 }}>{site.siteId ?? "unknown"}</div>
                    <div style={{ color: "#475569", fontSize: 14 }}>{site.namespace}</div>
                  </div>
                  {site.siteId ? (
                    <form action={deleteSiteAction}>
                      <input type="hidden" name="siteId" value={site.siteId} />
                      <button type="submit" style={{ color: "crimson" }}>Delete</button>
                    </form>
                  ) : null}
                </div>
              </li>
            ))}
          </ul>
        )}
      </section>
    </main>
  );
}
