import { promises as fs } from "node:fs";
import path from "node:path";
import { HttpError } from "../http/errors.js";

const DEFAULT_PATH = "/etc/voxeil/allowlist.txt";
const ENTRY_PATTERN = /^[0-9A-Fa-f:.\/]+$/;

function resolvePath(): string {
  return process.env.ALLOWLIST_PATH?.trim() || DEFAULT_PATH;
}

function normalizeEntry(value: string): string {
  const trimmed = value.trim();
  if (!trimmed) {
    throw new HttpError(400, "Allowlist entry cannot be empty.");
  }
  if (!ENTRY_PATTERN.test(trimmed)) {
    throw new HttpError(400, `Invalid allowlist entry: ${trimmed}`);
  }
  return trimmed;
}

export async function readAllowlist(): Promise<string[]> {
  const filePath = resolvePath();
  try {
    const content = await fs.readFile(filePath, "utf8");
    return content
      .split(/\r?\n/)
      .map((line) => line.trim())
      .filter((line) => line && !line.startsWith("#"));
  } catch (error: any) {
    if (error?.code === "ENOENT") return [];
    throw new HttpError(500, "Failed to read allowlist.");
  }
}

export async function writeAllowlist(items: string[]): Promise<string[]> {
  const filePath = resolvePath();
  const dir = path.dirname(filePath);
  const normalized = items.map(normalizeEntry);
  await fs.mkdir(dir, { recursive: true });
  const content = normalized.length > 0 ? normalized.join("\n") + "\n" : "";
  await fs.writeFile(filePath, content, "utf8");
  return normalized;
}
