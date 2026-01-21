import jwt from "jsonwebtoken";
import { HttpError } from "../http/errors.js";

export type JWTPayload = {
  sub: string; // user-id
  role: "admin" | "user";
  disabled: boolean;
  iat?: number;
  exp?: number;
};

const JWT_SECRET = process.env.JWT_SECRET;
if (!JWT_SECRET) {
  throw new Error("JWT_SECRET environment variable is required");
}

const JWT_EXPIRES_IN = process.env.JWT_EXPIRES_IN ?? "12h";

/**
 * Creates a JWT token for a user
 */
export function createToken(payload: Omit<JWTPayload, "iat" | "exp">): string {
  return jwt.sign(payload, JWT_SECRET, {
    expiresIn: JWT_EXPIRES_IN,
    issuer: "voxeil-controller"
  });
}

/**
 * Verifies and decodes a JWT token
 */
export function verifyToken(token: string): JWTPayload {
  try {
    const decoded = jwt.verify(token, JWT_SECRET, {
      issuer: "voxeil-controller"
    }) as JWTPayload;
    return decoded;
  } catch (error: any) {
    if (error.name === "TokenExpiredError") {
      throw new HttpError(401, "Token expired");
    }
    if (error.name === "JsonWebTokenError") {
      throw new HttpError(401, "Invalid token");
    }
    throw new HttpError(401, "Token verification failed");
  }
}

/**
 * Extracts JWT token from Authorization header
 */
export function extractTokenFromHeader(
  headers: Record<string, string | string[] | undefined>
): string {
  const authHeader = headers.authorization || headers["x-authorization"];
  const headerValue = Array.isArray(authHeader) ? authHeader[0] : authHeader;
  
  if (!headerValue) {
    throw new HttpError(401, "Authorization header is required");
  }

  // Support both "Bearer <token>" and direct token
  if (headerValue.startsWith("Bearer ")) {
    return headerValue.slice(7);
  }
  
  return headerValue;
}
