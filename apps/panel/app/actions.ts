"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createSite, deleteSite } from "./lib/controller.js";
import { clearSession, requireSession } from "./lib/session.js";

export async function createSiteAction(formData: FormData) {
  requireSession();

  const domain = String(formData.get("domain") ?? "").trim();
  const cpu = Number(formData.get("cpu") ?? "1");
  const ramGi = Number(formData.get("ramGi") ?? "2");
  const diskGi = Number(formData.get("diskGi") ?? "10");
  const tlsEnabled = String(formData.get("tlsEnabled") ?? "") === "on";
  const tlsIssuer = String(formData.get("tlsIssuer") ?? "").trim();

  if (!domain || Number.isNaN(cpu) || Number.isNaN(ramGi) || Number.isNaN(diskGi)) {
    throw new Error("domain, cpu, ramGi, and diskGi are required.");
  }

  await createSite({
    domain,
    cpu,
    ramGi,
    diskGi,
    tlsEnabled: tlsEnabled || undefined,
    tlsIssuer: tlsIssuer || undefined
  });
  revalidatePath("/");
}

export async function deleteSiteAction(formData: FormData) {
  requireSession();
  const slug = String(formData.get("slug") ?? "").trim();
  if (!slug) throw new Error("slug is required.");

  await deleteSite(slug);
  revalidatePath("/");
}

export async function logoutAction() {
  clearSession();
  redirect("/login");
}
