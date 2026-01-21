export function slugFromDomain(input) {
    let value = input.trim().toLowerCase();
    if (!value) {
        throw new Error("Domain is required.");
    }
    if (value.includes("://")) {
        try {
            value = new URL(value).hostname.toLowerCase();
        }
        catch {
            // fall through to best-effort parsing below
        }
    }
    value = value.split("/")[0] ?? value;
    value = value.split(":")[0] ?? value;
    value = value.replace(/\.$/, "");
    const parts = value.split(".").filter(Boolean);
    value = parts.join(".");
    value = value.replace(/[^a-z0-9]+/g, "-");
    value = value.replace(/-+/g, "-").replace(/^-+|-+$/g, "");
    if (!value) {
        throw new Error("Domain cannot be normalized into a slug.");
    }
    return value;
}
export function validateSlug(input) {
    const value = input.trim().toLowerCase();
    if (!value) {
        throw new Error("Slug is required.");
    }
    if (!/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(value)) {
        throw new Error("Slug must be lowercase and contain only a-z, 0-9, or hyphen.");
    }
    return value;
}
