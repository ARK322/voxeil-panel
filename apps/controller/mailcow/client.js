import { HttpError } from "../http/errors.js";
const DEFAULT_TIMEOUT_MS = 15000;
function resolveMailcowConfig() {
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
function toErrorMessage(result) {
    if (!result) {
        return undefined;
    }
    const entries = Array.isArray(result) ? result : [result];
    const messages = entries
        .map((entry) => {
        if (!entry || typeof entry !== "object") {
            return undefined;
        }
        const candidate = entry;
        const resultType = String(candidate.type ?? "").trim().toLowerCase();
        if (resultType && resultType !== "error" && resultType !== "danger" && resultType !== "warning") {
            return undefined;
        }
        return String(candidate.msg ?? candidate.message ?? "").trim();
    })
        .filter((value) => Boolean(value));
    if (messages.length === 0) {
        return undefined;
    }
    return messages.join("; ");
}
function isExistsMessage(message) {
    if (!message) {
        return false;
    }
    return message.toLowerCase().includes("exist");
}
function isMissingMessage(message) {
    if (!message) {
        return false;
    }
    const normalized = message.toLowerCase();
    return (normalized.includes("not exist") ||
        normalized.includes("does not exist") ||
        normalized.includes("not found"));
}
function toHttpErrorMessage(error, fallback) {
    if (!error) {
        return fallback;
    }
    if (typeof error === "string") {
        return error;
    }
    if (typeof error === "object" && "message" in error) {
        const message = String(error.message ?? "").trim();
        if (message) {
            return message;
        }
    }
    return fallback;
}
async function mailcowRequest(path, init) {
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
        const data = text ? JSON.parse(text) : undefined;
        if (!response.ok) {
            const message = toErrorMessage(data) ?? `Mailcow request failed (${response.status}).`;
            throw new HttpError(502, message);
        }
        return data;
    }
    catch (error) {
        if (error?.name === "AbortError") {
            throw new HttpError(504, "Mailcow request timed out.");
        }
        if (error instanceof HttpError) {
            throw error;
        }
        throw new HttpError(502, toHttpErrorMessage(error, "Mailcow request failed."));
    }
    finally {
        clearTimeout(timeout);
        if (!config.verifyTls) {
            if (previousTls === undefined) {
                delete process.env.NODE_TLS_REJECT_UNAUTHORIZED;
            }
            else {
                process.env.NODE_TLS_REJECT_UNAUTHORIZED = previousTls;
            }
        }
    }
}
async function listMailcowDomains() {
    const result = await mailcowRequest("/api/v1/get/domain/all", { method: "GET" });
    if (!Array.isArray(result)) {
        throw new HttpError(502, "Mailcow returned an unexpected domain list.");
    }
    return result
        .map((entry) => {
        if (typeof entry === "string") {
            return entry.trim().toLowerCase();
        }
        if (entry && typeof entry === "object" && "domain" in entry) {
            const domain = entry.domain;
            return (domain ?? "").trim().toLowerCase();
        }
        return "";
    })
        .filter(Boolean);
}
function buildDomainPayload(domain) {
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
function normalizeDomain(domain) {
    return domain.trim().toLowerCase().replace(/\.$/, "");
}
function extractMailboxAddress(entry) {
    if (entry.username) {
        return String(entry.username).trim().toLowerCase();
    }
    if (entry.address) {
        return String(entry.address).trim().toLowerCase();
    }
    const local = entry.local_part ? String(entry.local_part).trim() : "";
    const domain = entry.domain ? String(entry.domain).trim() : "";
    if (local && domain) {
        return `${local}@${domain}`.toLowerCase();
    }
    return "";
}
function extractAliasAddress(entry) {
    if (entry.address) {
        return String(entry.address).trim().toLowerCase();
    }
    if (entry.alias) {
        return String(entry.alias).trim().toLowerCase();
    }
    return "";
}
export async function ensureMailcowDomain(domain) {
    const normalized = normalizeDomain(domain);
    if (!normalized) {
        throw new HttpError(400, "Domain is required.");
    }
    const existing = await listMailcowDomains();
    if (existing.includes(normalized)) {
        return;
    }
    const result = await mailcowRequest("/api/v1/add/domain", {
        method: "POST",
        body: JSON.stringify(buildDomainPayload(normalized))
    });
    const message = toErrorMessage(result);
    if (message && !isExistsMessage(message)) {
        throw new HttpError(502, message);
    }
}
export async function setMailcowDomainActive(domain, active) {
    const normalized = normalizeDomain(domain);
    if (!normalized) {
        throw new HttpError(400, "Domain is required.");
    }
    const result = await mailcowRequest("/api/v1/edit/domain", {
        method: "POST",
        body: JSON.stringify({
            items: [normalized],
            attr: { active: active ? 1 : 0 }
        })
    });
    const message = toErrorMessage(result);
    if (message && !isExistsMessage(message)) {
        throw new HttpError(502, message);
    }
}
export async function listMailcowMailboxes(domain) {
    const normalized = normalizeDomain(domain);
    if (!normalized) {
        throw new HttpError(400, "Domain is required.");
    }
    const result = await mailcowRequest("/api/v1/get/mailbox/all", { method: "GET" });
    if (!Array.isArray(result)) {
        throw new HttpError(502, "Mailcow returned an unexpected mailbox list.");
    }
    return result
        .map((entry) => {
        if (!entry || typeof entry !== "object") {
            return "";
        }
        return extractMailboxAddress(entry);
    })
        .filter((address) => address.endsWith(`@${normalized}`));
}
export async function listMailcowAliases(domain) {
    const normalized = normalizeDomain(domain);
    if (!normalized) {
        throw new HttpError(400, "Domain is required.");
    }
    const result = await mailcowRequest("/api/v1/get/alias/all", { method: "GET" });
    if (!Array.isArray(result)) {
        throw new HttpError(502, "Mailcow returned an unexpected alias list.");
    }
    return result
        .map((entry) => {
        if (!entry || typeof entry !== "object") {
            return "";
        }
        return extractAliasAddress(entry);
    })
        .filter((address) => address.endsWith(`@${normalized}`));
}
export async function createMailcowAlias(options) {
    const sourceAddress = options.sourceAddress.trim().toLowerCase();
    const destinationAddress = options.destinationAddress.trim();
    if (!sourceAddress) {
        throw new HttpError(400, "sourceAddress is required.");
    }
    if (!destinationAddress) {
        throw new HttpError(400, "destinationAddress is required.");
    }
    if (!sourceAddress.includes("@")) {
        throw new HttpError(400, "sourceAddress must be a valid email address.");
    }
    const result = await mailcowRequest("/api/v1/add/alias", {
        method: "POST",
        body: JSON.stringify({
            address: sourceAddress,
            goto: destinationAddress,
            active: options.active === false ? 0 : 1
        })
    });
    const message = toErrorMessage(result);
    if (message && !isExistsMessage(message)) {
        throw new HttpError(502, message);
    }
    return sourceAddress;
}
export async function deleteMailcowAlias(address) {
    await deleteMailcowAliases([address]);
}
export async function createMailcowMailbox(options) {
    const domain = normalizeDomain(options.domain);
    const localPart = options.localPart.trim();
    if (!domain) {
        throw new HttpError(400, "Domain is required.");
    }
    if (!localPart) {
        throw new HttpError(400, "localPart is required.");
    }
    if (!options.password) {
        throw new HttpError(400, "password is required.");
    }
    const address = `${localPart}@${domain}`.toLowerCase();
    const result = await mailcowRequest("/api/v1/add/mailbox", {
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
        throw new HttpError(502, message);
    }
    return address;
}
export async function deleteMailcowMailbox(address) {
    const normalized = address.trim().toLowerCase();
    if (!normalized) {
        return;
    }
    try {
        const result = await mailcowRequest("/api/v1/delete/mailbox", {
            method: "POST",
            body: JSON.stringify([normalized])
        });
        const message = toErrorMessage(result);
        if (message && !isMissingMessage(message)) {
            throw new HttpError(502, message);
        }
    }
    catch (error) {
        const message = String(error?.message ?? "");
        if (isMissingMessage(message)) {
            return;
        }
        if (error instanceof HttpError) {
            throw error;
        }
        throw new HttpError(502, toHttpErrorMessage(error, "Mailcow delete mailbox failed."));
    }
}
export async function deleteMailcowAliases(addresses) {
    const items = addresses.map((address) => address.trim().toLowerCase()).filter(Boolean);
    if (items.length === 0) {
        return;
    }
    try {
        const result = await mailcowRequest("/api/v1/delete/alias", {
            method: "POST",
            body: JSON.stringify(items)
        });
        const message = toErrorMessage(result);
        if (message && !isMissingMessage(message)) {
            throw new HttpError(502, message);
        }
    }
    catch (error) {
        const message = String(error?.message ?? "");
        if (isMissingMessage(message)) {
            return;
        }
        if (error instanceof HttpError) {
            throw error;
        }
        throw new HttpError(502, toHttpErrorMessage(error, "Mailcow delete alias failed."));
    }
}
export async function deleteMailcowDomain(domain) {
    const normalized = normalizeDomain(domain);
    if (!normalized) {
        return;
    }
    try {
        const result = await mailcowRequest("/api/v1/delete/domain", {
            method: "POST",
            body: JSON.stringify([normalized])
        });
        const message = toErrorMessage(result);
        if (message && !isMissingMessage(message)) {
            throw new HttpError(502, message);
        }
    }
    catch (error) {
        const message = String(error?.message ?? "");
        if (isMissingMessage(message)) {
            return;
        }
        if (error instanceof HttpError) {
            throw error;
        }
        throw new HttpError(502, toHttpErrorMessage(error, "Mailcow delete domain failed."));
    }
}
export async function getMailcowDomainActive(domain) {
    const normalized = normalizeDomain(domain);
    if (!normalized) {
        throw new HttpError(400, "Domain is required.");
    }
    const result = await mailcowRequest(`/api/v1/get/domain/${normalized}`, {
        method: "GET"
    });
    const entry = Array.isArray(result) ? result[0] : result;
    if (!entry || typeof entry !== "object") {
        throw new HttpError(502, "Mailcow returned an unexpected domain response.");
    }
    const activeValue = entry.active;
    if (activeValue === undefined || activeValue === null) {
        throw new HttpError(502, "Mailcow domain status is unavailable.");
    }
    if (typeof activeValue === "number") {
        return activeValue === 1;
    }
    return String(activeValue).trim() === "1";
}
export async function purgeMailcowDomain(domain) {
    const normalized = normalizeDomain(domain);
    if (!normalized) {
        throw new HttpError(400, "Domain is required.");
    }
    const errors = [];
    try {
        const [mailboxes, aliases] = await Promise.all([
            listMailcowMailboxes(normalized),
            listMailcowAliases(normalized)
        ]);
        try {
            await deleteMailcowAliases(aliases);
        }
        catch (error) {
            errors.push(toHttpErrorMessage(error, "Mailcow alias cleanup failed."));
        }
        const mailboxResults = await Promise.allSettled(mailboxes.map(async (address) => deleteMailcowMailbox(address)));
        for (const result of mailboxResults) {
            if (result.status === "rejected") {
                errors.push(toHttpErrorMessage(result.reason, "Mailcow mailbox cleanup failed."));
            }
        }
        try {
            await deleteMailcowDomain(normalized);
        }
        catch (error) {
            errors.push(toHttpErrorMessage(error, "Mailcow domain cleanup failed."));
        }
    }
    catch (error) {
        errors.push(toHttpErrorMessage(error, "Mailcow purge failed."));
    }
    if (errors.length > 0) {
        throw new HttpError(502, errors.join(" "));
    }
}
export const ensureDomain = ensureMailcowDomain;
export const setDomainActive = setMailcowDomainActive;
export const listMailboxes = listMailcowMailboxes;
export const createMailbox = createMailcowMailbox;
export const deleteMailbox = deleteMailcowMailbox;
export const listAliases = listMailcowAliases;
export const createAlias = createMailcowAlias;
export const deleteAlias = deleteMailcowAlias;
export const purgeDomain = purgeMailcowDomain;
