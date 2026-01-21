import jwt from "jsonwebtoken";
import { HttpError } from "../http/errors.js";

const JWT_SECRET = process.env.JWT_SECRET;
if (!JWT_SECRET) {
    throw new Error("JWT_SECRET env var is required (provided via Secret).");
}

const JWT_EXPIRES_IN = process.env.JWT_EXPIRES_IN ?? "12h";

export function signToken(payload) {
    return jwt.sign(payload, JWT_SECRET, { expiresIn: JWT_EXPIRES_IN });
}

export function verifyToken(token) {
    try {
        const decoded = jwt.verify(token, JWT_SECRET);
        if (decoded.disabled === true) {
            throw new HttpError(403, "User is disabled.");
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
