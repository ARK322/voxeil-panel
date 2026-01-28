// Wrapper around @voxeil/api-client that uses panel's session management
import { getSessionToken } from "./session";
import { createControllerClient } from "@voxeil/api-client";
import type { SiteInfo, PanelUser } from "@voxeil/api-client";

const CONTROLLER_BASE =
  process.env.CONTROLLER_BASE_URL ?? "http://controller.platform.svc.cluster.local:8080";

const client = createControllerClient(() => getSessionToken(), CONTROLLER_BASE);

// Re-export types for backward compatibility
export type { SiteInfo, PanelUser };

// Re-export all functions with same signatures
export const listSites = client.sites.list;
export const createSite = client.sites.create;
export const deleteSite = client.sites.delete;
export const enableGithub = client.sites.enableGithub;
export const disableGithub = client.sites.disableGithub;
export const deployGithub = client.sites.deployGithub;
export const saveRegistryCredentials = client.sites.saveRegistryCredentials;
export const deleteRegistryCredentials = client.sites.deleteRegistryCredentials;
export const getAllowlist = client.security.getAllowlist;
export const updateAllowlist = client.security.updateAllowlist;
export const updateSiteTls = client.sites.updateTls;
export const updateSiteLimits = client.sites.updateLimits;
export const enableSiteDb = client.sites.enableDb;
export const disableSiteDb = client.sites.disableDb;
export const purgeSiteDb = client.sites.purgeDb;
export const enableSiteMail = client.sites.enableMail;
export const disableSiteMail = client.sites.disableMail;
export const purgeSiteMail = client.sites.purgeMail;
export const listSiteMailboxes = client.sites.listMailboxes;
export const createSiteMailbox = client.sites.createMailbox;
export const deleteSiteMailbox = client.sites.deleteMailbox;
export const listSiteAliases = client.sites.listAliases;
export const createSiteAlias = client.sites.createAlias;
export const deleteSiteAlias = client.sites.deleteAlias;
export const enableSiteDns = client.sites.enableDns;
export const disableSiteDns = client.sites.disableDns;
export const purgeSiteDns = client.sites.purgeDns;
export const listUsers = client.users.list;
export const createUser = client.users.create;
export const setUserActive = client.users.setActive;
export const removeUser = client.users.remove;
export const logoutSession = client.auth.logout;
