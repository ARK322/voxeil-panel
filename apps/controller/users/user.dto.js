import { z } from "zod";

// Strong password schema with all security requirements
const passwordSchema = z.string()
    .min(8, "Password must be at least 8 characters long")
    .max(128, "Password must be at most 128 characters long")
    .refine(
        (password) => /[A-Z]/.test(password),
        "Password must contain at least one uppercase letter"
    )
    .refine(
        (password) => /[a-z]/.test(password),
        "Password must contain at least one lowercase letter"
    )
    .refine(
        (password) => /[0-9]/.test(password),
        "Password must contain at least one number"
    )
    .refine(
        (password) => /[^A-Za-z0-9]/.test(password),
        "Password must contain at least one special character"
    );

export const UserRoleSchema = z.enum(["admin", "user"]);
export const CreateUserSchema = z.object({
    username: z.string()
        .min(3, "Username must be at least 3 characters")
        .max(32, "Username must be at most 32 characters")
        .regex(/^[a-z0-9_-]+$/, "Username can only contain lowercase letters, numbers, hyphens, and underscores"),
    password: passwordSchema,
    email: z.string()
        .email("Invalid email address")
        .toLowerCase()
        .trim(),
    role: UserRoleSchema
});
export const LoginSchema = z.object({
    username: z.string().min(1, "Username is required").trim(),
    password: z.string().min(1, "Password is required")
});
export const ToggleUserSchema = z.object({
    active: z.boolean()
});
export const ChangePasswordSchema = z.object({
    currentPassword: z.string().min(1, "Current password is required"),
    newPassword: passwordSchema
});