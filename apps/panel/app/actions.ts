"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createSite, deleteSite } from "./lib/controller.js";
import { clearSession, requireSession } from "./lib/session.js";

export async function createSiteAction(formData: FormData) {
  requireSession();

  const siteId = String(formData.get("siteId") ?? "").trim();
  const image = String(formData.get("image") ?? "").trim();
  const containerPort = Number(formData.get("containerPort") ?? "3000");

  if (!siteId || !image || Number.isNaN(containerPort)) {
    throw new Error("siteId, image, and containerPort are required.");
  }

  await createSite({ siteId, image, containerPort });
  revalidatePath("/");
}

export async function deleteSiteAction(formData: FormData) {
  requireSession();
  const siteId = String(formData.get("siteId") ?? "").trim();
  if (!siteId) throw new Error("siteId is required.");

  await deleteSite(siteId);
  revalidatePath("/");
}

export async function logoutAction() {
  clearSession();
  redirect("/login");
}
