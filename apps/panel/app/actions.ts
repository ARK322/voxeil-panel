"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import {
  createSite,
  deleteSite,
  deployGithub,
  disableGithub,
  enableGithub,
  saveRegistryCredentials,
  deleteRegistryCredentials,
  updateAllowlist,
  createUser,
  setUserActive,
  removeUser,
  logoutSession,
  updateSiteTls,
  updateSiteLimits,
  enableSiteDb,
  disableSiteDb,
  purgeSiteDb,
  enableSiteMail,
  disableSiteMail,
  purgeSiteMail,
  createSiteMailbox,
  deleteSiteMailbox,
  createSiteAlias,
  deleteSiteAlias,
  enableSiteDns,
  disableSiteDns,
  purgeSiteDns
} from "./lib/controller";
import { clearSession, requireSession } from "./lib/session";

export async function createSiteAction(formData: FormData) {
  const session = await requireSession();

  const domain = String(formData.get("domain") ?? "").trim();
  const cpu = Number(formData.get("cpu") ?? "1");
  const ramGi = Number(formData.get("ramGi") ?? "2");
  const diskGi = Number(formData.get("diskGi") ?? "10");
  const tlsEnabled = String(formData.get("tlsEnabled") ?? "") === "on";
  const tlsIssuer = String(formData.get("tlsIssuer") ?? "").trim();
  const userUsername = String(formData.get("userUsername") ?? "").trim();
  const userEmail = String(formData.get("userEmail") ?? "").trim();
  const userPassword = String(formData.get("userPassword") ?? "").trim();

  if (!domain || Number.isNaN(cpu) || Number.isNaN(ramGi) || Number.isNaN(diskGi)) {
    throw new Error("domain, cpu, ramGi, and diskGi are required.");
  }

  const site = await createSite({
    domain,
    cpu,
    ramGi,
    diskGi,
    tlsEnabled: tlsEnabled || undefined,
    tlsIssuer: tlsIssuer || undefined
  });

  if (userUsername || userEmail || userPassword) {
    if (!userUsername || !userEmail || !userPassword) {
      throw new Error("Site user username, email, and password are required.");
    }
    if (session.user.role !== "admin") {
      throw new Error("Only admins can create site users.");
    }
    await createUser({
      username: userUsername,
      email: userEmail,
      password: userPassword,
      role: "site",
      siteSlug: site.slug
    });
  }
  revalidatePath("/");
}

export async function deleteSiteAction(formData: FormData) {
  await requireSession();
  const slug = String(formData.get("slug") ?? "").trim();
  if (!slug) throw new Error("slug is required.");

  await deleteSite(slug);
  revalidatePath("/");
}

export async function enableGithubAction(formData: FormData) {
  await requireSession();
  const slug = String(formData.get("slug") ?? "").trim();
  const repo = String(formData.get("repo") ?? "").trim();
  const branch = String(formData.get("branch") ?? "").trim();
  const workflow = String(formData.get("workflow") ?? "").trim();
  const image = String(formData.get("image") ?? "").trim();
  const token = String(formData.get("token") ?? "").trim();
  const webhookSecret = String(formData.get("webhookSecret") ?? "").trim();
  if (!slug || !repo || !image || !token) {
    throw new Error("slug, repo, image, and token are required.");
  }

  await enableGithub({
    slug,
    repo,
    branch: branch || undefined,
    workflow: workflow || undefined,
    image,
    token,
    webhookSecret: webhookSecret || undefined
  });
  revalidatePath("/");
}

export async function disableGithubAction(formData: FormData) {
  await requireSession();
  const slug = String(formData.get("slug") ?? "").trim();
  if (!slug) throw new Error("slug is required.");
  await disableGithub(slug);
  revalidatePath("/");
}

export async function deployGithubAction(formData: FormData) {
  await requireSession();
  const slug = String(formData.get("slug") ?? "").trim();
  const ref = String(formData.get("ref") ?? "").trim();
  const image = String(formData.get("image") ?? "").trim();
  const registryUsername = String(formData.get("registryUsername") ?? "").trim();
  const registryToken = String(formData.get("registryToken") ?? "").trim();
  const registryServer = String(formData.get("registryServer") ?? "").trim();
  const registryEmail = String(formData.get("registryEmail") ?? "").trim();
  if (!slug) throw new Error("slug is required.");
  await deployGithub({
    slug,
    ref: ref || undefined,
    image: image || undefined,
    registryUsername: registryUsername || undefined,
    registryToken: registryToken || undefined,
    registryServer: registryServer || undefined,
    registryEmail: registryEmail || undefined
  });
  revalidatePath("/");
}

export async function saveRegistryCredentialsAction(formData: FormData) {
  await requireSession();
  const slug = String(formData.get("slug") ?? "").trim();
  const registryUsername = String(formData.get("registryUsername") ?? "").trim();
  const registryToken = String(formData.get("registryToken") ?? "").trim();
  const registryServer = String(formData.get("registryServer") ?? "").trim();
  const registryEmail = String(formData.get("registryEmail") ?? "").trim();
  if (!slug) throw new Error("slug is required.");
  if (!registryUsername || !registryToken) {
    throw new Error("registryUsername and registryToken are required.");
  }
  await saveRegistryCredentials({
    slug,
    registryUsername,
    registryToken,
    registryServer: registryServer || undefined,
    registryEmail: registryEmail || undefined
  });
  revalidatePath("/");
}

export async function deleteRegistryCredentialsAction(formData: FormData) {
  await requireSession();
  const slug = String(formData.get("slug") ?? "").trim();
  if (!slug) throw new Error("slug is required.");
  await deleteRegistryCredentials(slug);
  revalidatePath("/");
}

export async function updateAllowlistAction(formData: FormData) {
  await requireSession();
  const raw = String(formData.get("allowlist") ?? "");
  const items = raw
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line && !line.startsWith("#"));
  await updateAllowlist(items);
  revalidatePath("/");
}

export async function logoutAction() {
  try {
    await logoutSession();
  } finally {
    clearSession();
  }
  redirect("/login");
}

export async function createUserAction(formData: FormData) {
  const session = await requireSession();
  if (session.user.role !== "admin") {
    throw new Error("Admin access required.");
  }
  const username = String(formData.get("username") ?? "").trim();
  const email = String(formData.get("email") ?? "").trim();
  const password = String(formData.get("password") ?? "").trim();
  const role = String(formData.get("role") ?? "site");
  const siteSlug = String(formData.get("siteSlug") ?? "").trim();
  if (!username || !email || !password) {
    throw new Error("username, email, and password are required.");
  }
  if (role !== "admin" && !siteSlug) {
    throw new Error("siteSlug is required for site users.");
  }
  await createUser({
    username,
    email,
    password,
    role: role === "admin" ? "admin" : "site",
    siteSlug: role === "site" ? siteSlug : undefined
  });
  revalidatePath("/");
}

export async function toggleUserAction(formData: FormData) {
  const session = await requireSession();
  if (session.user.role !== "admin") {
    throw new Error("Admin access required.");
  }
  const id = String(formData.get("id") ?? "").trim();
  const active = String(formData.get("active") ?? "") === "true";
  if (!id) throw new Error("id is required.");
  await setUserActive(id, active);
  revalidatePath("/");
}

export async function deleteUserAction(formData: FormData) {
  const session = await requireSession();
  if (session.user.role !== "admin") {
    throw new Error("Admin access required.");
  }
  const id = String(formData.get("id") ?? "").trim();
  if (!id) throw new Error("id is required.");
  await removeUser(id);
  revalidatePath("/");
}

export async function updateTlsAction(formData: FormData) {
  await requireSession();
  const slug = String(formData.get("slug") ?? "").trim();
  const enabled = String(formData.get("enabled") ?? "") === "true";
  const issuer = String(formData.get("issuer") ?? "").trim();
  const cleanupSecret = String(formData.get("cleanupSecret") ?? "") === "true";
  if (!slug) throw new Error("slug is required.");
  await updateSiteTls({ slug, enabled, issuer: issuer || undefined, cleanupSecret });
  revalidatePath("/");
}

export async function updateLimitsAction(formData: FormData) {
  const session = await requireSession();
  if (session.user.role !== "admin") {
    throw new Error("Admin access required.");
  }
  const slug = String(formData.get("slug") ?? "").trim();
  const cpu = Number(formData.get("cpu") ?? "");
  const ramGi = Number(formData.get("ramGi") ?? "");
  const diskGi = Number(formData.get("diskGi") ?? "");
  if (!slug) throw new Error("slug is required.");
  await updateSiteLimits({
    slug,
    cpu: Number.isNaN(cpu) ? undefined : cpu,
    ramGi: Number.isNaN(ramGi) ? undefined : ramGi,
    diskGi: Number.isNaN(diskGi) ? undefined : diskGi
  });
  revalidatePath("/");
}

export async function enableDbAction(formData: FormData) {
  await requireSession();
  const slug = String(formData.get("slug") ?? "").trim();
  const dbName = String(formData.get("dbName") ?? "").trim();
  if (!slug) throw new Error("slug is required.");
  await enableSiteDb(slug, dbName || undefined);
  revalidatePath("/");
}

export async function disableDbAction(formData: FormData) {
  await requireSession();
  const slug = String(formData.get("slug") ?? "").trim();
  if (!slug) throw new Error("slug is required.");
  await disableSiteDb(slug);
  revalidatePath("/");
}

export async function purgeDbAction(formData: FormData) {
  await requireSession();
  const slug = String(formData.get("slug") ?? "").trim();
  if (!slug) throw new Error("slug is required.");
  await purgeSiteDb(slug);
  revalidatePath("/");
}

export async function enableMailAction(formData: FormData) {
  await requireSession();
  const slug = String(formData.get("slug") ?? "").trim();
  const domain = String(formData.get("domain") ?? "").trim();
  if (!slug || !domain) throw new Error("slug and domain are required.");
  await enableSiteMail(slug, domain);
  revalidatePath("/");
}

export async function disableMailAction(formData: FormData) {
  await requireSession();
  const slug = String(formData.get("slug") ?? "").trim();
  if (!slug) throw new Error("slug is required.");
  await disableSiteMail(slug);
  revalidatePath("/");
}

export async function purgeMailAction(formData: FormData) {
  await requireSession();
  const slug = String(formData.get("slug") ?? "").trim();
  if (!slug) throw new Error("slug is required.");
  await purgeSiteMail(slug);
  revalidatePath("/");
}

export async function createMailboxAction(formData: FormData) {
  await requireSession();
  const slug = String(formData.get("slug") ?? "").trim();
  const localPart = String(formData.get("localPart") ?? "").trim();
  const password = String(formData.get("password") ?? "").trim();
  const quotaMb = Number(formData.get("quotaMb") ?? "");
  if (!slug || !localPart || !password) {
    throw new Error("slug, localPart, and password are required.");
  }
  await createSiteMailbox({
    slug,
    localPart,
    password,
    quotaMb: Number.isNaN(quotaMb) ? undefined : quotaMb
  });
  revalidatePath("/");
}

export async function deleteMailboxAction(formData: FormData) {
  await requireSession();
  const slug = String(formData.get("slug") ?? "").trim();
  const address = String(formData.get("address") ?? "").trim();
  if (!slug || !address) {
    throw new Error("slug and address are required.");
  }
  await deleteSiteMailbox(slug, address);
  revalidatePath("/");
}

export async function createAliasAction(formData: FormData) {
  await requireSession();
  const slug = String(formData.get("slug") ?? "").trim();
  const sourceLocalPart = String(formData.get("sourceLocalPart") ?? "").trim();
  const destination = String(formData.get("destination") ?? "").trim();
  const active = String(formData.get("active") ?? "") !== "false";
  if (!slug || !sourceLocalPart || !destination) {
    throw new Error("slug, sourceLocalPart, and destination are required.");
  }
  await createSiteAlias({ slug, sourceLocalPart, destination, active });
  revalidatePath("/");
}

export async function deleteAliasAction(formData: FormData) {
  await requireSession();
  const slug = String(formData.get("slug") ?? "").trim();
  const source = String(formData.get("source") ?? "").trim();
  if (!slug || !source) {
    throw new Error("slug and source are required.");
  }
  await deleteSiteAlias(slug, source);
  revalidatePath("/");
}

export async function enableDnsAction(formData: FormData) {
  await requireSession();
  const slug = String(formData.get("slug") ?? "").trim();
  const domain = String(formData.get("domain") ?? "").trim();
  const targetIp = String(formData.get("targetIp") ?? "").trim();
  if (!slug || !domain || !targetIp) {
    throw new Error("slug, domain, and targetIp are required.");
  }
  await enableSiteDns(slug, domain, targetIp);
  revalidatePath("/");
}

export async function disableDnsAction(formData: FormData) {
  await requireSession();
  const slug = String(formData.get("slug") ?? "").trim();
  if (!slug) throw new Error("slug is required.");
  await disableSiteDns(slug);
  revalidatePath("/");
}

export async function purgeDnsAction(formData: FormData) {
  await requireSession();
  const slug = String(formData.get("slug") ?? "").trim();
  if (!slug) throw new Error("slug is required.");
  await purgeSiteDns(slug);
  revalidatePath("/");
}
