import { z } from "zod";
export const UserRoleSchema = z.enum(["admin", "user"]);
export const CreateUserSchema = z.object({
    username: z.string().min(1),
    password: z.string().min(8),
    email: z.string().email(),
    role: UserRoleSchema
});
export const LoginSchema = z.object({
    username: z.string().min(1),
    password: z.string().min(1)
});
export const ToggleUserSchema = z.object({
    active: z.boolean()
});
