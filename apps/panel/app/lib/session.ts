import { cookies } from "next/headers";
import { redirect } from "next/navigation";

const SESSION_COOKIE = "vhp_panel_session";
const SESSION_TTL_SECONDS = 60 * 60 * 12; // 12h

const CONTROLLER_BASE =
  process.env.CONTROLLER_BASE_URL ?? "http://controller.platform.svc.cluster.local:8080";

export type SessionUser = {
  id: string;
  username: string;
  email: string;
  role: "admin" | "site";
  siteSlug?: string | null;
  active: boolean;
  createdAt: string;
};

export type SessionInfo = {
  token: string;
  user: SessionUser;
  expiresAt: string;
};

export function getSessionToken(): string | null {
  return cookies().get(SESSION_COOKIE)?.value ?? null;
}

export async function requireSession(): Promise<SessionInfo> {
  const token = getSessionToken();
  if (!token) redirect("/login");

  const res = await fetch(`${CONTROLLER_BASE}/auth/session`, {
    headers: { "x-session-token": token },
    cache: "no-store"
  });
  if (!res.ok) {
    clearSession();
    redirect("/login");
  }
  const payload = (await res.json()) as { user: SessionUser; expiresAt: string };
  return { token, user: payload.user, expiresAt: payload.expiresAt };
}

export function establishSession(token: string) {
  cookies().set({
    name: SESSION_COOKIE,
    value: token,
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
