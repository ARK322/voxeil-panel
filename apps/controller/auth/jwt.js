import jwt from "jsonwebtoken";
import crypto from "node:crypto";
import { HttpError } from "../http/errors.js";
import { isTokenRevoked } from "./token-revocation.service.js";
import { logger } from "../config/logger.js";

const JWT_SECRET = process.env.JWT_SECRET;

// Validate JWT secret exists and meets security requirements
if (!JWT_SECRET) {
    throw new Error("JWT_SECRET environment variable is required.");
}

if (JWT_SECRET.length < 32) {
    throw new Error("JWT_SECRET must be at least 32 characters long for security.");
}

// Warn if secret looks weak (optional but recommended)
const hasUpperCase = /[A-Z]/.test(JWT_SECRET);
const hasLowerCase = /[a-z]/.test(JWT_SECRET);
const hasNumber = /[0-9]/.test(JWT_SECRET);
const hasSpecial = /[^A-Za-z0-9]/.test(JWT_SECRET);

if (!(hasUpperCase && hasLowerCase && hasNumber && hasSpecial)) {
    logger.warn("JWT_SECRET should contain uppercase, lowercase, numbers, and special characters for maximum security");
}

const JWT_EXPIRES_IN = process.env.JWT_EXPIRES_IN ?? "12h";

export function signToken(payload) {
    // Production-ready: add a jti so tokens can be revoked on logout/refresh.
    const jti = crypto.randomUUID();
    return jwt.sign(payload, JWT_SECRET, { expiresIn: JWT_EXPIRES_IN, jwtid: jti });
}

export async function verifyToken(token) {
    try {
        const decoded = jwt.verify(token, JWT_SECRET);
        if (decoded.disabled === true) {
            throw new HttpError(403, "User is disabled.");
        }
        // Production-ready: enforce logout/refresh invalidation via revocation store.
        if (decoded?.jti) {
            const revoked = await isTokenRevoked(decoded.jti).catch((err) => {
                // Fail closed: if we can't check revocation state, auth is unsafe.
                throw new HttpError(503, `Auth revocation check failed: ${err?.message ?? String(err)}`);
            });
            if (revoked) {
                throw new HttpError(401, "Token revoked.");
            }
        }
        return decoded;
    } catch (error) {
        if (error instanceof HttpError) {
            throw error;
        }
        if (error instanceof jwt.JsonWebTokenError) {
            throw new HttpError(401, "Invalid token.");
        }
        if (error instanceof jwt.TokenExpiredError) {
            throw new HttpError(401, "Token expired.");
        }
        throw new HttpError(401, "Token verification failed.");
    }
}

export function extractTokenFromHeader(headers) {
    const authHeader = headers.authorization;
    if (!authHeader) {
        return null;
    }
    const parts = Array.isArray(authHeader) ? authHeader[0] : authHeader;
    if (typeof parts !== "string") {
        return null;
    }
    const match = parts.match(/^Bearer\s+(.+)$/i);
    return match ? match[1] : null;
}
