import { HttpError } from "../http/errors.js";

type MailcowConfig = {
  baseUrl: string;
  apiKey: string;
  verifyTls: boolean;
  timeoutMs: number;
};

type MailcowResult = {
  type?: string;
  msg?: string;
  message?: string;
};

const DEFAULT_TIMEOUT_MS = 15000;

function resolveMailcowConfig(): MailcowConfig {
  const baseUrl = (process.env.MAILCOW_API_URL ?? "").trim().replace(/\/+$/, "");
  if (!baseUrl) {
    throw new HttpError(500, "MAILCOW_API_URL must be set.");
  }
  const apiKey = (process.env.MAILCOW_API_KEY ?? "").trim();
  if (!apiKey) {
    throw new HttpError(500, "MAILCOW_API_KEY must be set.");
  }
  const verifyTls = (process.env.MAILCOW_VERIFY_TLS ?? "true").toLowerCase() !== "false";
  return {
    baseUrl,
    apiKey,
    verifyTls,
    timeoutMs: DEFAULT_TIMEOUT_MS
  };
}

function toErrorMessage(result: unknown): string | undefined {
  if (!result) return undefined;
  const entries = Array.isArray(result) ? result : [result];
  const messages = entries
    .map((entry) => {
      if (!entry || typeof entry !== "object") return undefined;
      const candidate = entry as MailcowResult;
      return String(candidate.msg ?? candidate.message ?? "").trim();
    })
    .filter((value): value is string => Boolean(value));
  if (messages.length === 0) return undefined;
  return messages.join("; ");
}

function isExistsMessage(message?: string): boolean {
  if (!message) return false;
  return message.toLowerCase().includes("exist");
}

async function mailcowRequest<T>(
  path: string,
  init: RequestInit
): Promise<T> {
  const config = resolveMailcowConfig();
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), config.timeoutMs);
  const previousTls = process.env.NODE_TLS_REJECT_UNAUTHORIZED;
  if (!config.verifyTls) {
    process.env.NODE_TLS_REJECT_UNAUTHORIZED = "0";
  }
  try {
    const response = await fetch(`${config.baseUrl}${path}`, {
      ...init,
      headers: {
        "Content-Type": "application/json",
        "X-API-Key": config.apiKey,
        ...(init.headers ?? {})
      },
      signal: controller.signal
    });
    const text = await response.text();
    const data = text ? (JSON.parse(text) as T) : (undefined as T);
    if (!response.ok) {
      const message = toErrorMessage(data) ?? `Mailcow request failed (${response.status}).`;
      throw new Error(message);
    }
    return data;
  } catch (error: any) {
    if (error?.name === "AbortError") {
      throw new Error("Mailcow request timed out.");
    }
    throw error;
  } finally {
    clearTimeout(timeout);
    if (!config.verifyTls) {
      if (previousTls === undefined) {
        delete process.env.NODE_TLS_REJECT_UNAUTHORIZED;
      } else {
        process.env.NODE_TLS_REJECT_UNAUTHORIZED = previousTls;
      }
    }
  }
}

async function listMailcowDomains(): Promise<string[]> {
  const result = await mailcowRequest<unknown>("/api/v1/get/domain/all", { method: "GET" });
  if (!Array.isArray(result)) return [];
  return result
    .map((entry) => {
      if (typeof entry === "string") return entry.trim().toLowerCase();
      if (entry && typeof entry === "object" && "domain" in entry) {
        const domain = (entry as { domain?: string }).domain;
        return (domain ?? "").trim().toLowerCase();
      }
      return "";
    })
    .filter(Boolean);
}

function buildDomainPayload(domain: string) {
  return {
    domain,
    description: "",
    aliases: 0,
    mailboxes: 0,
    maxquota: 0,
    quota: 0,
    defquota: 0,
    maxmsgsize: 0,
    active: 1,
    relay_all_recipients: 0,
    backupmx: 0,
    relayhost: "",
    gal: 0
  };
}

export async function ensureMailcowDomain(domain: string): Promise<void> {
  const normalized = domain.trim().toLowerCase();
  if (!normalized) {
    throw new Error("Domain is required.");
  }
  const existing = await listMailcowDomains();
  if (existing.includes(normalized)) {
    return;
  }
  const result = await mailcowRequest<unknown>("/api/v1/add/domain", {
    method: "POST",
    body: JSON.stringify(buildDomainPayload(normalized))
  });
  const message = toErrorMessage(result);
  if (message && !isExistsMessage(message)) {
    throw new Error(message);
  }
}
