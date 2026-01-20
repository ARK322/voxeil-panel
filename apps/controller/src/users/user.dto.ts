import { z } from "zod";

export const UserRoleSchema = z.enum(["admin", "site"]);

export const CreateUserSchema = z
  .object({
    username: z.string().min(1),
    password: z.string().min(8),
    email: z.string().email(),
    role: UserRoleSchema,
    siteSlug: z.string().min(1).optional()
  })
  .refine(
    (value) =>
      (value.role === "admin" && !value.siteSlug) ||
      (value.role === "site" && Boolean(value.siteSlug)),
    {
      message: "siteSlug is required for site users and must be empty for admins."
    }
  );

export const LoginSchema = z.object({
  username: z.string().min(1),
  password: z.string().min(1)
});

export const ToggleUserSchema = z.object({
  active: z.boolean()
});

export type CreateUserInput = z.infer<typeof CreateUserSchema>;
export type LoginInput = z.infer<typeof LoginSchema>;
