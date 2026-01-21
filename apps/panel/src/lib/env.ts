// Environment variable validation

export const env = {
  PANEL_BASE_URL: process.env.PANEL_BASE_URL || (typeof window !== "undefined" ? window.location.origin : ""),
  MAIL_UI_URL: process.env.NEXT_PUBLIC_MAIL_UI_URL || process.env.MAIL_UI_URL || "",
  PGADMIN_URL: process.env.NEXT_PUBLIC_PGADMIN_URL || process.env.PGADMIN_URL || "",
  CONTROLLER_BASE_URL: process.env.NEXT_PUBLIC_CONTROLLER_BASE_URL || process.env.CONTROLLER_BASE_URL || "http://controller.platform.svc.cluster.local:8080",
} as const;
