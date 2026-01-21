const store = new Map();
export function checkRateLimit(key, config) {
    const now = Date.now();
    const entry = store.get(key);
    if (!entry || now >= entry.resetAt) {
        store.set(key, { count: 1, resetAt: now + config.windowMs });
        return { allowed: true, remaining: config.limit - 1, resetAt: now + config.windowMs };
    }
    if (entry.count >= config.limit) {
        return { allowed: false, remaining: 0, resetAt: entry.resetAt };
    }
    entry.count += 1;
    return { allowed: true, remaining: config.limit - entry.count, resetAt: entry.resetAt };
}
export function pruneRateLimitStore() {
    const now = Date.now();
    for (const [key, entry] of store.entries()) {
        if (now >= entry.resetAt) {
            store.delete(key);
        }
    }
}
