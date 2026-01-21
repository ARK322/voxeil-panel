import type { FastifyRequest, FastifyReply } from "fastify";
import { HttpError } from "../http/errors.js";
import { verifyToken, extractTokenFromHeader, type JWTPayload } from "./jwt.js";

export type AuthenticatedRequest = FastifyRequest & {
  user: JWTPayload;
};

/**
 * JWT Authentication Middleware
 * Verifies JWT token and attaches user payload to request
 */
export async function authenticateJWT(
  request: FastifyRequest,
  reply: FastifyReply
): Promise<void> {
  try {
    const token = extractTokenFromHeader(request.headers);
    const payload = verifyToken(token);

    // Check if user is disabled
    if (payload.disabled) {
      throw new HttpError(403, "User is disabled");
    }

    // Attach user to request
    (request as AuthenticatedRequest).user = payload;
  } catch (error) {
    if (error instanceof HttpError) {
      throw error;
    }
    throw new HttpError(401, "Authentication failed");
  }
}

/**
 * Middleware to require admin role
 */
export async function requireAdmin(
  request: FastifyRequest,
  reply: FastifyReply
): Promise<void> {
  await authenticateJWT(request, reply);
  const user = (request as AuthenticatedRequest).user;
  
  if (user.role !== "admin") {
    throw new HttpError(403, "Admin access required");
  }
}

/**
 * Helper to get authenticated user from request
 */
export function getAuthenticatedUser(request: FastifyRequest): JWTPayload {
  const user = (request as AuthenticatedRequest).user;
  if (!user) {
    throw new HttpError(401, "User not authenticated");
  }
  return user;
}
