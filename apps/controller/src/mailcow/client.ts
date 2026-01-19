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

type MailcowMailbox = {
  username?: string;
  address?: string;
  domain?: string;
  local_part?: string;
};

type MailcowAlias = {
  address?: string;
  alias?: string;
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

function isMissingMessage(message?: string): boolean {
  if (!message) return false;
  const normalized = message.toLowerCase();
  return (
    normalized.includes("not exist") ||
    normalized.includes("does not exist") ||
    normalized.includes("not found")
  );
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

function normalizeDomain(domain: string): string {
  return domain.trim().toLowerCase().replace(/\.$/, "");
}

function extractMailboxAddress(entry: MailcowMailbox): string {
  if (entry.username) return String(entry.username).trim().toLowerCase();
  if (entry.address) return String(entry.address).trim().toLowerCase();
  const local = entry.local_part ? String(entry.local_part).trim() : "";
  const domain = entry.domain ? String(entry.domain).trim() : "";
  if (local && domain) return `${local}@${domain}`.toLowerCase();
  return "";
}

function extractAliasAddress(entry: MailcowAlias): string {
  if (entry.address) return String(entry.address).trim().toLowerCase();
  if (entry.alias) return String(entry.alias).trim().toLowerCase();
  return "";
}

export async function ensureMailcowDomain(domain: string): Promise<void> {
  const normalized = normalizeDomain(domain);
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

export async function setMailcowDomainActive(domain: string, active: boolean): Promise<void> {
  const normalized = normalizeDomain(domain);
  if (!normalized) {
    throw new Error("Domain is required.");
  }
  const result = await mailcowRequest<unknown>("/api/v1/edit/domain", {
    method: "POST",
    body: JSON.stringify({
      items: [normalized],
      attr: { active: active ? 1 : 0 }
    })
  });
  const message = toErrorMessage(result);
  if (message && !isExistsMessage(message) && !isMissingMessage(message)) {
    throw new Error(message);
  }
}

export async function listMailcowMailboxes(domain: string): Promise<string[]> {
  const normalized = normalizeDomain(domain);
  if (!normalized) return [];
  const result = await mailcowRequest<unknown>("/api/v1/get/mailbox/all", { method: "GET" });
  if (!Array.isArray(result)) return [];
  return result
    .map((entry) => {
      if (!entry || typeof entry !== "object") return "";
      return extractMailboxAddress(entry as MailcowMailbox);
    })
    .filter((address) => address.endsWith(`@${normalized}`));
}

export async function listMailcowAliases(domain: string): Promise<string[]> {
  const normalized = normalizeDomain(domain);
  if (!normalized) return [];
  const result = await mailcowRequest<unknown>("/api/v1/get/alias/all", { method: "GET" });
  if (!Array.isArray(result)) return [];
  return result
    .map((entry) => {
      if (!entry || typeof entry !== "object") return "";
      return extractAliasAddress(entry as MailcowAlias);
    })
    .filter((address) => address.endsWith(`@${normalized}`));
}

export async function createMailcowMailbox(options: {
  domain: string;
  localPart: string;
  password: string;
  quotaMb?: number;
}): Promise<string> {
  const domain = normalizeDomain(options.domain);
  const localPart = options.localPart.trim();
  if (!domain) throw new Error("Domain is required.");
  if (!localPart) throw new Error("localPart is required.");
  if (!options.password) throw new Error("password is required.");
  const address = `${localPart}@${domain}`.toLowerCase();
  const result = await mailcowRequest<unknown>("/api/v1/add/mailbox", {
    method: "POST",
    body: JSON.stringify({
      local_part: localPart,
      domain,
      name: localPart,
      password: options.password,
      password2: options.password,
      quota: options.quotaMb ?? 0,
      active: 1
    })
  });
  const message = toErrorMessage(result);
  if (message && !isExistsMessage(message)) {
    throw new Error(message);
  }
  return address;
}

export async function deleteMailcowMailbox(address: string): Promise<void> {
  const normalized = address.trim().toLowerCase();
  if (!normalized) return;
  try {
    const result = await mailcowRequest<unknown>("/api/v1/delete/mailbox", {
      method: "POST",
      body: JSON.stringify([normalized])
    });
    const message = toErrorMessage(result);
    if (message && !isMissingMessage(message)) {
      throw new Error(message);
    }
  } catch (error: any) {
    const message = String(error?.message ?? "");
    if (isMissingMessage(message)) return;
    throw error;
  }
}

export async function deleteMailcowAliases(addresses: string[]): Promise<void> {
  const items = addresses.map((address) => address.trim().toLowerCase()).filter(Boolean);
  if (items.length === 0) return;
  try {
    const result = await mailcowRequest<unknown>("/api/v1/delete/alias", {
      method: "POST",
      body: JSON.stringify(items)
    });
    const message = toErrorMessage(result);
    if (message && !isMissingMessage(message)) {
      throw new Error(message);
    }
  } catch (error: any) {
    const message = String(error?.message ?? "");
    if (isMissingMessage(message)) return;
    throw error;
  }
}

export async function deleteMailcowDomain(domain: string): Promise<void> {
  const normalized = normalizeDomain(domain);
  if (!normalized) return;
  try {
    const result = await mailcowRequest<unknown>("/api/v1/delete/domain", {
      method: "POST",
      body: JSON.stringify([normalized])
    });
    const message = toErrorMessage(result);
    if (message && !isMissingMessage(message)) {
      throw new Error(message);
    }
  } catch (error: any) {
    const message = String(error?.message ?? "");
    if (isMissingMessage(message)) return;
    throw error;
  }
}
