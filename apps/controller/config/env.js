/**
 * Parse and validate environment variable as number
 */
export function parseEnvNumber(key, defaultValue, options = {}) {
    const value = process.env[key];
    if (!value) return defaultValue;
    
    const parsed = parseInt(value, 10);
    if (isNaN(parsed)) {
        throw new Error(`Environment variable ${key} must be a number, got: ${value}`);
    }
    
    if (options.min !== undefined && parsed < options.min) {
        throw new Error(`Environment variable ${key} must be >= ${options.min}, got: ${parsed}`);
    }
    
    if (options.max !== undefined && parsed > options.max) {
        throw new Error(`Environment variable ${key} must be <= ${options.max}, got: ${parsed}`);
    }
    
    return parsed;
}

/**
 * Parse and validate environment variable as boolean
 */
export function parseEnvBoolean(key, defaultValue) {
    const value = process.env[key];
    if (!value) return defaultValue;
    
    const normalized = value.toLowerCase().trim();
    if (["true", "1", "yes"].includes(normalized)) return true;
    if (["false", "0", "no"].includes(normalized)) return false;
    
    throw new Error(`Environment variable ${key} must be a boolean, got: ${value}`);
}

/**
 * Require environment variable to be set
 */
export function requireEnv(key) {
    const value = process.env[key];
    if (!value) {
        throw new Error(`Required environment variable ${key} is not set`);
    }
    return value.trim();
}

/**
 * Parse environment variable as array (comma-separated)
 */
export function parseEnvArray(key, defaultValue = []) {
    const value = process.env[key];
    if (!value) return defaultValue;
    
    return value.split(',').map(item => item.trim()).filter(Boolean);
}
