import {
  createSiteAction,
  deleteSiteAction,
  deployGithubAction,
  disableGithubAction,
  enableGithubAction,
  saveRegistryCredentialsAction,
  deleteRegistryCredentialsAction,
  logoutAction,
  updateAllowlistAction,
  createUserAction,
  toggleUserAction,
  deleteUserAction,
  updateTlsAction,
  updateLimitsAction,
  enableDbAction,
  disableDbAction,
  purgeDbAction,
  enableMailAction,
  disableMailAction,
  purgeMailAction,
  createMailboxAction,
  deleteMailboxAction,
  createAliasAction,
  deleteAliasAction,
  enableDnsAction,
  disableDnsAction,
  purgeDnsAction
} from "./actions";
import {
  getAllowlist,
  listSites,
  listUsers,
  listSiteMailboxes,
  listSiteAliases
} from "./lib/controller";
import { requireSession } from "./lib/session";
import { LogStream } from "./components/log-stream";

export default async function HomePage() {
  const session = await requireSession();
  const isAdmin = session.user.role === "admin";
  const sites = await listSites();
  const visibleSites = isAdmin
    ? sites
    : sites.filter((site) => site.slug === session.user.siteSlug);
  const mailboxMap = new Map<string, string[]>();
  const aliasMap = new Map<string, string[]>();
  for (const site of visibleSites) {
    if (site.mailEnabled) {
      const [mailboxes, aliases] = await Promise.all([
        listSiteMailboxes(site.slug),
        listSiteAliases(site.slug)
      ]);
      mailboxMap.set(site.slug, mailboxes);
      aliasMap.set(site.slug, aliases);
    }
  }
  const allowlist = isAdmin ? await getAllowlist() : [];
  const users = isAdmin ? await listUsers() : [];

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

      {isAdmin ? (
        <section style={{ marginTop: 24 }}>
          <h2>Create site</h2>
          <form action={createSiteAction} style={{ display: "grid", gap: 12, maxWidth: 420 }}>
            <label style={{ display: "grid", gap: 6 }}>
              <span>Domain</span>
              <input name="domain" type="text" placeholder="app.example.com" required />
            </label>
            <label style={{ display: "grid", gap: 6 }}>
              <span>CPU (cores)</span>
              <input name="cpu" type="number" min={1} defaultValue={1} required />
            </label>
            <label style={{ display: "grid", gap: 6 }}>
              <span>RAM (Gi)</span>
              <input name="ramGi" type="number" min={1} defaultValue={2} required />
            </label>
            <label style={{ display: "grid", gap: 6 }}>
              <span>Disk (Gi)</span>
              <input name="diskGi" type="number" min={1} defaultValue={10} required />
            </label>
            <label style={{ display: "grid", gap: 6 }}>
              <span>TLS</span>
              <div style={{ display: "flex", gap: 8, alignItems: "center" }}>
                <input name="tlsEnabled" type="checkbox" />
                <select name="tlsIssuer" defaultValue="letsencrypt-prod">
                  <option value="letsencrypt-staging">letsencrypt-staging</option>
                  <option value="letsencrypt-prod">letsencrypt-prod</option>
                </select>
              </div>
            </label>
            <fieldset style={{ border: "1px solid #e2e8f0", borderRadius: 8, padding: 12 }}>
              <legend style={{ padding: "0 6px" }}>Create site user (optional)</legend>
              <label style={{ display: "grid", gap: 6 }}>
                <span>Username</span>
                <input name="userUsername" placeholder="site-user" />
              </label>
              <label style={{ display: "grid", gap: 6 }}>
                <span>Email</span>
                <input name="userEmail" type="email" placeholder="user@example.com" />
              </label>
              <label style={{ display: "grid", gap: 6 }}>
                <span>Password</span>
                <input name="userPassword" type="password" />
              </label>
            </fieldset>
            <button type="submit" style={{ padding: "10px 16px" }}>Create</button>
          </form>
        </section>
      ) : null}

      {isAdmin ? (
        <section style={{ marginTop: 32 }}>
          <h2>Security allowlist</h2>
          <p style={{ color: "#475569", marginTop: 4 }}>
            One IP or CIDR per line. Leave empty to allow all.
          </p>
          <form action={updateAllowlistAction} style={{ display: "grid", gap: 8, maxWidth: 520 }}>
            <textarea
              name="allowlist"
              rows={6}
              defaultValue={allowlist.join("\n")}
              placeholder="203.0.113.10\n198.51.100.0/24"
            />
            <button type="submit">Save allowlist</button>
          </form>
        </section>
      ) : null}

      {isAdmin ? (
        <section style={{ marginTop: 32 }}>
          <h2>Users</h2>
          <form action={createUserAction} style={{ display: "grid", gap: 8, maxWidth: 520 }}>
            <label style={{ display: "grid", gap: 6 }}>
              <span>Username</span>
              <input name="username" required />
            </label>
            <label style={{ display: "grid", gap: 6 }}>
              <span>Email</span>
              <input name="email" type="email" required />
            </label>
            <label style={{ display: "grid", gap: 6 }}>
              <span>Password</span>
              <input name="password" type="password" required />
            </label>
            <label style={{ display: "grid", gap: 6 }}>
              <span>Role</span>
              <select name="role" defaultValue="site">
                <option value="site">site</option>
                <option value="admin">admin</option>
              </select>
            </label>
            <label style={{ display: "grid", gap: 6 }}>
              <span>Site (for site users)</span>
              <select name="siteSlug" defaultValue="">
                <option value="">Select site</option>
                {sites.map((site) => (
                  <option key={site.slug} value={site.slug}>
                    {site.slug}
                  </option>
                ))}
              </select>
            </label>
            <button type="submit">Create user</button>
          </form>
          {users.length === 0 ? (
            <p style={{ marginTop: 12 }}>No users yet.</p>
          ) : (
            <ul style={{ listStyle: "none", padding: 0, display: "grid", gap: 12, marginTop: 12 }}>
              {users.map((user) => (
                <li key={user.id} style={{ border: "1px solid #e2e8f0", borderRadius: 8, padding: 12 }}>
                  <div style={{ display: "flex", justifyContent: "space-between", gap: 12 }}>
                    <div>
                      <div style={{ fontWeight: 600 }}>{user.username}</div>
                      <div style={{ color: "#475569", fontSize: 14 }}>{user.email}</div>
                      <div style={{ color: "#475569", fontSize: 14 }}>
                        {user.role} {user.siteSlug ? `• ${user.siteSlug}` : ""}
                      </div>
                    </div>
                    <div style={{ display: "flex", gap: 8, alignItems: "center" }}>
                      <form action={toggleUserAction}>
                        <input type="hidden" name="id" value={user.id} />
                        <input type="hidden" name="active" value={user.active ? "false" : "true"} />
                        <button type="submit">{user.active ? "Disable" : "Enable"}</button>
                      </form>
                      <form action={deleteUserAction}>
                        <input type="hidden" name="id" value={user.id} />
                        <button type="submit" style={{ color: "crimson" }}>Delete</button>
                      </form>
                    </div>
                  </div>
                </li>
              ))}
            </ul>
          )}
        </section>
      ) : null}

      <section style={{ marginTop: 32 }}>
        <h2>Existing sites</h2>
        {visibleSites.length === 0 ? (
          <p>No sites yet.</p>
        ) : (
          <ul style={{ listStyle: "none", padding: 0, display: "grid", gap: 12 }}>
            {visibleSites.map(site => (
              <li key={site.namespace} style={{ border: "1px solid #e2e8f0", borderRadius: 8, padding: 12 }}>
                <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
                  <div>
                    <div style={{ fontWeight: 600 }}>{site.slug}</div>
                    <div style={{ color: "#475569", fontSize: 14 }}>{site.namespace}</div>
                    {site.domain ? (
                      <div style={{ color: "#475569", fontSize: 14 }}>{site.domain}</div>
                    ) : null}
                  </div>
                  {site.slug && isAdmin ? (
                    <form action={deleteSiteAction}>
                      <input type="hidden" name="slug" value={site.slug} />
                      <button type="submit" style={{ color: "crimson" }}>Delete</button>
                    </form>
                  ) : null}
                </div>
                <details style={{ marginTop: 12 }}>
                  <summary style={{ cursor: "pointer" }}>GitHub Deploy</summary>
                  <div style={{ marginTop: 12, display: "grid", gap: 12 }}>
                    <form action={enableGithubAction} style={{ display: "grid", gap: 8 }}>
                      <input type="hidden" name="slug" value={site.slug} />
                      <label style={{ display: "grid", gap: 6 }}>
                        <span>Repo (owner/repo or URL)</span>
                        <input name="repo" defaultValue={site.githubRepo ?? ""} required />
                      </label>
                      <label style={{ display: "grid", gap: 6 }}>
                        <span>Branch</span>
                        <input name="branch" defaultValue={site.githubBranch ?? "main"} />
                      </label>
                      <label style={{ display: "grid", gap: 6 }}>
                        <span>Workflow file</span>
                        <input name="workflow" defaultValue={site.githubWorkflow ?? "panel-build.yml"} />
                      </label>
                      <label style={{ display: "grid", gap: 6 }}>
                        <span>Image (GHCR)</span>
                        <input name="image" defaultValue={site.githubImage ?? ""} required />
                      </label>
                      <label style={{ display: "grid", gap: 6 }}>
                        <span>GitHub Token</span>
                        <input name="token" type="password" required />
                      </label>
                      <label style={{ display: "grid", gap: 6 }}>
                        <span>Webhook Secret</span>
                        <input name="webhookSecret" type="password" placeholder="optional but recommended" />
                      </label>
                      <button type="submit">Save GitHub Config</button>
                    </form>
                    <form action={deployGithubAction} style={{ display: "grid", gap: 8 }}>
                      <input type="hidden" name="slug" value={site.slug} />
                      <label style={{ display: "grid", gap: 6 }}>
                        <span>Deploy ref (optional)</span>
                        <input name="ref" placeholder={site.githubBranch ?? "main"} />
                      </label>
                      <label style={{ display: "grid", gap: 6 }}>
                        <span>Image override (optional)</span>
                        <input name="image" placeholder={site.githubImage ?? ""} />
                      </label>
                      <label style={{ display: "grid", gap: 6 }}>
                        <span>Registry username (optional)</span>
                        <input name="registryUsername" placeholder="ghcr-username" />
                      </label>
                      <label style={{ display: "grid", gap: 6 }}>
                        <span>Registry token (optional)</span>
                        <input name="registryToken" type="password" />
                      </label>
                      <label style={{ display: "grid", gap: 6 }}>
                        <span>Registry server (optional)</span>
                        <input name="registryServer" placeholder="ghcr.io" />
                      </label>
                      <label style={{ display: "grid", gap: 6 }}>
                        <span>Registry email (optional)</span>
                        <input name="registryEmail" placeholder="you@example.com" />
                      </label>
                      <button type="submit">Trigger Build & Deploy</button>
                    </form>
                    <form action={disableGithubAction}>
                      <input type="hidden" name="slug" value={site.slug} />
                      <button type="submit" style={{ color: "crimson" }}>Disable GitHub</button>
                    </form>
                    <div style={{ marginTop: 16, paddingTop: 16, borderTop: "1px solid #e2e8f0" }}>
                      <h4 style={{ margin: "0 0 8px 0", fontSize: 14, fontWeight: 600 }}>Registry Credentials (Persistent)</h4>
                      <p style={{ margin: "0 0 12px 0", fontSize: 12, color: "#64748b" }}>
                        Save registry credentials once, use them for all future deploys. If not set, you'll need to provide them on each deploy.
                      </p>
                      <form action={saveRegistryCredentialsAction} style={{ display: "grid", gap: 8 }}>
                        <input type="hidden" name="slug" value={site.slug} />
                        <label style={{ display: "grid", gap: 6 }}>
                          <span>Registry username</span>
                          <input name="registryUsername" placeholder="ghcr-username" required />
                        </label>
                        <label style={{ display: "grid", gap: 6 }}>
                          <span>Registry token</span>
                          <input name="registryToken" type="password" placeholder="ghp_..." required />
                        </label>
                        <label style={{ display: "grid", gap: 6 }}>
                          <span>Registry server (optional)</span>
                          <input name="registryServer" placeholder="ghcr.io" defaultValue="ghcr.io" />
                        </label>
                        <label style={{ display: "grid", gap: 6 }}>
                          <span>Registry email (optional)</span>
                          <input name="registryEmail" type="email" placeholder="you@example.com" />
                        </label>
                        <button type="submit">Save Registry Credentials</button>
                      </form>
                      <form action={deleteRegistryCredentialsAction} style={{ marginTop: 8 }}>
                        <input type="hidden" name="slug" value={site.slug} />
                        <button type="submit" style={{ color: "crimson", fontSize: 12 }}>Delete Registry Credentials</button>
                      </form>
                    </div>
                  </div>
                </details>
                <details style={{ marginTop: 12 }}>
                  <summary style={{ cursor: "pointer" }}>Logs</summary>
                  <div style={{ marginTop: 12 }}>
                    <LogStream slug={site.slug} />
                  </div>
                </details>
                <details style={{ marginTop: 12 }}>
                  <summary style={{ cursor: "pointer" }}>Services</summary>
                  <div style={{ marginTop: 12, display: "grid", gap: 16 }}>
                    <section>
                      <h4 style={{ margin: "0 0 8px 0" }}>TLS</h4>
                      <form action={updateTlsAction} style={{ display: "grid", gap: 8, maxWidth: 420 }}>
                        <input type="hidden" name="slug" value={site.slug} />
                        <label style={{ display: "grid", gap: 6 }}>
                          <span>Enabled</span>
                          <select name="enabled" defaultValue={site.tlsEnabled ? "true" : "false"}>
                            <option value="true">Enabled</option>
                            <option value="false">Disabled</option>
                          </select>
                        </label>
                        <label style={{ display: "grid", gap: 6 }}>
                          <span>Issuer</span>
                          <select name="issuer" defaultValue={site.tlsIssuer ?? "letsencrypt-prod"}>
                            <option value="letsencrypt-staging">letsencrypt-staging</option>
                            <option value="letsencrypt-prod">letsencrypt-prod</option>
                          </select>
                        </label>
                        <label style={{ display: "grid", gap: 6 }}>
                          <span>Cleanup secret (when disabling)</span>
                          <select name="cleanupSecret" defaultValue="false">
                            <option value="false">No</option>
                            <option value="true">Yes</option>
                          </select>
                        </label>
                        <button type="submit">Update TLS</button>
                      </form>
                    </section>

                    {isAdmin ? (
                      <section>
                        <h4 style={{ margin: "0 0 8px 0" }}>Limits</h4>
                        <form action={updateLimitsAction} style={{ display: "grid", gap: 8, maxWidth: 420 }}>
                          <input type="hidden" name="slug" value={site.slug} />
                          <label style={{ display: "grid", gap: 6 }}>
                            <span>CPU (cores)</span>
                            <input name="cpu" type="number" min={1} defaultValue={site.cpu ?? 1} />
                          </label>
                          <label style={{ display: "grid", gap: 6 }}>
                            <span>RAM (Gi)</span>
                            <input name="ramGi" type="number" min={1} defaultValue={site.ramGi ?? 2} />
                          </label>
                          <label style={{ display: "grid", gap: 6 }}>
                            <span>Disk (Gi)</span>
                            <input name="diskGi" type="number" min={1} defaultValue={site.diskGi ?? 10} />
                          </label>
                          <button type="submit">Update limits</button>
                        </form>
                      </section>
                    ) : null}

                    <section>
                      <h4 style={{ margin: "0 0 8px 0" }}>Database</h4>
                      <div style={{ display: "grid", gap: 8, maxWidth: 420 }}>
                        {!site.dbEnabled ? (
                          <form action={enableDbAction} style={{ display: "grid", gap: 8 }}>
                            <input type="hidden" name="slug" value={site.slug} />
                            <label style={{ display: "grid", gap: 6 }}>
                              <span>DB name (optional)</span>
                              <input name="dbName" placeholder={`db_${site.slug}`} />
                            </label>
                            <button type="submit">Enable DB</button>
                          </form>
                        ) : (
                          <>
                            <div style={{ color: "#475569" }}>
                              Enabled: {site.dbName ?? "db"} • User: {site.dbUser ?? "user"}
                            </div>
                            <form action={disableDbAction}>
                              <input type="hidden" name="slug" value={site.slug} />
                              <button type="submit">Disable DB</button>
                            </form>
                            {isAdmin ? (
                              <form action={purgeDbAction}>
                                <input type="hidden" name="slug" value={site.slug} />
                                <button type="submit" style={{ color: "crimson" }}>Purge DB</button>
                              </form>
                            ) : null}
                          </>
                        )}
                      </div>
                    </section>

                    <section>
                      <h4 style={{ margin: "0 0 8px 0" }}>Mail</h4>
                      <div style={{ display: "grid", gap: 8, maxWidth: 520 }}>
                        {!site.mailEnabled ? (
                          <form action={enableMailAction} style={{ display: "grid", gap: 8 }}>
                            <input type="hidden" name="slug" value={site.slug} />
                            <label style={{ display: "grid", gap: 6 }}>
                              <span>Domain (must match site)</span>
                              <input name="domain" defaultValue={site.domain ?? ""} />
                            </label>
                            <button type="submit">Enable Mail</button>
                          </form>
                        ) : (
                          <>
                            <div style={{ color: "#475569" }}>Domain: {site.mailDomain ?? site.domain}</div>
                            <form action={disableMailAction}>
                              <input type="hidden" name="slug" value={site.slug} />
                              <button type="submit">Disable Mail</button>
                            </form>
                            <form action={purgeMailAction}>
                              <input type="hidden" name="slug" value={site.slug} />
                              <button type="submit" style={{ color: "crimson" }}>Purge Mail</button>
                            </form>
                            <div style={{ marginTop: 8 }}>
                              <strong>Mailboxes</strong>
                              <form action={createMailboxAction} style={{ display: "grid", gap: 8, marginTop: 8 }}>
                                <input type="hidden" name="slug" value={site.slug} />
                                <label style={{ display: "grid", gap: 6 }}>
                                  <span>Local part</span>
                                  <input name="localPart" placeholder="info" />
                                </label>
                                <label style={{ display: "grid", gap: 6 }}>
                                  <span>Password</span>
                                  <input name="password" type="password" />
                                </label>
                                <label style={{ display: "grid", gap: 6 }}>
                                  <span>Quota (MB)</span>
                                  <input name="quotaMb" type="number" min={1} />
                                </label>
                                <button type="submit">Create mailbox</button>
                              </form>
                              {(mailboxMap.get(site.slug) ?? []).length === 0 ? (
                                <div style={{ color: "#475569", marginTop: 6 }}>No mailboxes.</div>
                              ) : (
                                <ul style={{ listStyle: "none", padding: 0, marginTop: 6 }}>
                                  {(mailboxMap.get(site.slug) ?? []).map((addr) => (
                                    <li key={addr} style={{ display: "flex", justifyContent: "space-between" }}>
                                      <span>{addr}</span>
                                      <form action={deleteMailboxAction}>
                                        <input type="hidden" name="slug" value={site.slug} />
                                        <input type="hidden" name="address" value={addr} />
                                        <button type="submit" style={{ color: "crimson" }}>Delete</button>
                                      </form>
                                    </li>
                                  ))}
                                </ul>
                              )}
                            </div>
                            <div style={{ marginTop: 8 }}>
                              <strong>Aliases</strong>
                              <form action={createAliasAction} style={{ display: "grid", gap: 8, marginTop: 8 }}>
                                <input type="hidden" name="slug" value={site.slug} />
                                <label style={{ display: "grid", gap: 6 }}>
                                  <span>Source local part</span>
                                  <input name="sourceLocalPart" placeholder="info" />
                                </label>
                                <label style={{ display: "grid", gap: 6 }}>
                                  <span>Destination</span>
                                  <input name="destination" placeholder="dest@example.net" />
                                </label>
                                <label style={{ display: "grid", gap: 6 }}>
                                  <span>Active</span>
                                  <select name="active" defaultValue="true">
                                    <option value="true">Active</option>
                                    <option value="false">Inactive</option>
                                  </select>
                                </label>
                                <button type="submit">Create alias</button>
                              </form>
                              {(aliasMap.get(site.slug) ?? []).length === 0 ? (
                                <div style={{ color: "#475569", marginTop: 6 }}>No aliases.</div>
                              ) : (
                                <ul style={{ listStyle: "none", padding: 0, marginTop: 6 }}>
                                  {(aliasMap.get(site.slug) ?? []).map((addr) => (
                                    <li key={addr} style={{ display: "flex", justifyContent: "space-between" }}>
                                      <span>{addr}</span>
                                      <form action={deleteAliasAction}>
                                        <input type="hidden" name="slug" value={site.slug} />
                                        <input type="hidden" name="source" value={addr} />
                                        <button type="submit" style={{ color: "crimson" }}>Delete</button>
                                      </form>
                                    </li>
                                  ))}
                                </ul>
                              )}
                            </div>
                          </>
                        )}
                      </div>
                    </section>

                    <section>
                      <h4 style={{ margin: "0 0 8px 0" }}>DNS</h4>
                      <div style={{ display: "grid", gap: 8, maxWidth: 420 }}>
                        {!site.dnsEnabled ? (
                          <form action={enableDnsAction} style={{ display: "grid", gap: 8 }}>
                            <input type="hidden" name="slug" value={site.slug} />
                            <label style={{ display: "grid", gap: 6 }}>
                              <span>Domain</span>
                              <input name="domain" defaultValue={site.domain ?? ""} />
                            </label>
                            <label style={{ display: "grid", gap: 6 }}>
                              <span>Target IP</span>
                              <input name="targetIp" placeholder="203.0.113.10" />
                            </label>
                            <button type="submit">Enable DNS</button>
                          </form>
                        ) : (
                          <>
                            <div style={{ color: "#475569" }}>
                              Domain: {site.dnsDomain ?? site.domain} • Target: {site.dnsTarget ?? "-"}
                            </div>
                            <form action={disableDnsAction}>
                              <input type="hidden" name="slug" value={site.slug} />
                              <button type="submit">Disable DNS</button>
                            </form>
                            <form action={purgeDnsAction}>
                              <input type="hidden" name="slug" value={site.slug} />
                              <button type="submit" style={{ color: "crimson" }}>Purge DNS</button>
                            </form>
                          </>
                        )}
                      </div>
                    </section>
                  </div>
                </details>
              </li>
            ))}
          </ul>
        )}
      </section>
    </main>
  );
}
