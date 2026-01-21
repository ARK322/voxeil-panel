import { promises as fs } from "node:fs";
import path from "node:path";
import ipaddr from "ipaddr.js";
import { HttpError } from "../http/errors.js";
const DEFAULT_PATH = "/etc/voxeil/allowlist.txt";
const ENTRY_PATTERN = /^[0-9A-Fa-f:.\/]+$/;
const CACHE_TTL_MS = Number(process.env.ALLOWLIST_CACHE_TTL_MS ?? "5000");
let cachedAllowlist = null;
function resolvePath() {
    return process.env.ALLOWLIST_PATH?.trim() || DEFAULT_PATH;
}
function normalizeEntry(value) {
    const trimmed = value.trim();
    if (!trimmed) {
        throw new HttpError(400, "Allowlist entry cannot be empty.");
    }
    if (!ENTRY_PATTERN.test(trimmed)) {
        throw new HttpError(400, `Invalid allowlist entry: ${trimmed}`);
    }
    return trimmed;
}
function sanitizeEntry(value) {
    const trimmed = value.trim();
    if (!trimmed || trimmed.startsWith("#"))
        return null;
    if (!ENTRY_PATTERN.test(trimmed))
        return null;
    return trimmed;
}
function parseAddress(value) {
    if (!ipaddr.isValid(value))
        return null;
    const parsed = ipaddr.parse(value);
    if (parsed.kind() === "ipv6") {
        const ipv6 = parsed;
        if (ipv6.isIPv4MappedAddress()) {
            return ipv6.toIPv4Address();
        }
    }
    return parsed;
}
export function isIpAllowed(ip, allowlist) {
    if (allowlist.length === 0)
        return true;
    const address = parseAddress(ip);
    if (!address)
        return false;
    for (const entry of allowlist) {
        try {
            if (entry.includes("/")) {
                const [range, prefix] = ipaddr.parseCIDR(entry);
                let normalizedRange = range;
                if (range.kind() === "ipv6") {
                    const ipv6 = range;
                    if (ipv6.isIPv4MappedAddress()) {
                        normalizedRange = ipv6.toIPv4Address();
                    }
                }
                if (normalizedRange.kind() !== address.kind())
                    continue;
                if (address.match([normalizedRange, prefix]))
                    return true;
            }
            else {
                const entryAddr = parseAddress(entry);
                if (!entryAddr)
                    continue;
                if (entryAddr.kind() !== address.kind())
                    continue;
                if (entryAddr.toString() === address.toString())
                    return true;
            }
        }
        catch {
            continue;
        }
    }
    return false;
}
export async function readAllowlist() {
    if (cachedAllowlist && Date.now() - cachedAllowlist.loadedAt < CACHE_TTL_MS) {
        return cachedAllowlist.items;
    }
    const filePath = resolvePath();
    try {
        const content = await fs.readFile(filePath, "utf8");
        const items = content
            .split(/\r?\n/)
            .map(sanitizeEntry)
            .filter((line) => Boolean(line));
        cachedAllowlist = { items, loadedAt: Date.now() };
        return items;
    }
    catch (error) {
        if (error?.code === "ENOENT")
            return [];
        throw new HttpError(500, "Failed to read allowlist.");
    }
}
export async function writeAllowlist(items) {
    const filePath = resolvePath();
    const dir = path.dirname(filePath);
    const normalized = items.map(normalizeEntry);
    await fs.mkdir(dir, { recursive: true });
    const content = normalized.length > 0 ? normalized.join("\n") + "\n" : "";
    await fs.writeFile(filePath, content, "utf8");
    cachedAllowlist = { items: normalized, loadedAt: Date.now() };
    return normalized;
}
