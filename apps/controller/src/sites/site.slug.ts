export function slugFromDomain(input: string): string {
  let value = input.trim().toLowerCase();
  if (!value) {
    throw new Error("Domain is required.");
  }

  if (value.includes("://")) {
    try {
      value = new URL(value).hostname.toLowerCase();
    } catch {
      // fall through to best-effort parsing below
    }
  }

  value = value.split("/")[0] ?? value;
  value = value.split(":")[0] ?? value;
  value = value.replace(/\.$/, "");

  const parts = value.split(".").filter(Boolean);
  if (parts.length >= 2) {
    parts.pop();
  }
  value = parts.join(".");

  value = value.replace(/[^a-z0-9]+/g, "-");
  value = value.replace(/-+/g, "-").replace(/^-+|-+$/g, "");

  if (!value) {
    throw new Error("Domain cannot be normalized into a slug.");
  }

  return value;
}
