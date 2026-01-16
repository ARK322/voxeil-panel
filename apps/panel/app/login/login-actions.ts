"use server";

import { establishSession, hasSession } from "../lib/session.js";

type LoginState = { success: boolean; error?: string };

export async function loginAction(
  _prevState: LoginState,
  formData: FormData
): Promise<LoginState> {
  if (hasSession()) return { success: true };

  const provided = String(formData.get("password") ?? "");
  const adminPassword = process.env.PANEL_ADMIN_PASSWORD;
  if (!adminPassword) {
    return { success: false, error: "PANEL_ADMIN_PASSWORD is not set." };
  }

  if (provided !== adminPassword) {
    return { success: false, error: "Invalid password." };
  }

  establishSession();
  return { success: true };
}
