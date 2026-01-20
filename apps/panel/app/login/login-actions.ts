"use server";

import { establishSession, getSessionToken } from "../lib/session";

type LoginState = { success: boolean; error?: string };

export async function loginAction(
  _prevState: LoginState,
  formData: FormData
): Promise<LoginState> {
  if (getSessionToken()) return { success: true };

  const providedUsername = String(formData.get("username") ?? "");
  const providedPassword = String(formData.get("password") ?? "");
  const controllerBase =
    process.env.CONTROLLER_BASE_URL ?? "http://controller.platform.svc.cluster.local:8080";

  const res = await fetch(`${controllerBase}/auth/login`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ username: providedUsername, password: providedPassword })
  });

  if (!res.ok) {
    const text = await res.text().catch(() => "");
    return { success: false, error: text || "Invalid credentials." };
  }

  const payload = (await res.json()) as { token?: string };
  if (!payload.token) {
    return { success: false, error: "Login failed." };
  }

  establishSession(payload.token);
  return { success: true };
}
