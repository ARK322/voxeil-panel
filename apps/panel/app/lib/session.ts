import crypto from "crypto";
import { cookies } from "next/headers";
import { redirect } from "next/navigation";

const SESSION_COOKIE = "vhp_panel_session";
const SESSION_TTL_SECONDS = 60 * 60 * 12; // 12h

function sessionValue(): string {
  const password = process.env.PANEL_ADMIN_PASSWORD;
  if (!password) {
    throw new Error("PANEL_ADMIN_PASSWORD is not set (injected via Secret).");
  }
  return crypto.createHash("sha256").update(password).digest("hex");
}

export function hasSession(): boolean {
  const current = cookies().get(SESSION_COOKIE)?.value;
  return current === sessionValue();
}

export function requireSession() {
  if (!hasSession()) redirect("/login");
}

export function establishSession() {
  cookies().set({
    name: SESSION_COOKIE,
    value: sessionValue(),
    httpOnly: true,
    sameSite: "lax",
    secure: false,
    path: "/",
    maxAge: SESSION_TTL_SECONDS
  });
}

export function clearSession() {
  cookies().delete(SESSION_COOKIE);
}
