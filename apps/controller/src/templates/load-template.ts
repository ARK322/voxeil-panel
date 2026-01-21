import { promises as fs, existsSync } from "node:fs";
import path from "node:path";
import k8s from "@kubernetes/client-node";

type TemplateVariables = Record<string, string>;

/**
 * Resolves template directory path
 */
function resolveTemplatesDir(): string {
  const candidates = [
    path.resolve(process.cwd(), "infra", "k8s", "templates", "user"),
    path.resolve(process.cwd(), "..", "..", "infra", "k8s", "templates", "user"),
    path.resolve(process.cwd(), "..", "infra", "k8s", "templates", "user"),
    path.resolve(process.cwd(), "templates", "user")
  ];

  for (const candidate of candidates) {
    if (existsSync(candidate)) {
      return candidate;
    }
  }

  throw new Error(`Template directory not found. Searched: ${candidates.join(", ")}`);
}

/**
 * Reads and processes a template file, replacing placeholders
 */
export async function loadAndRenderTemplate(
  templateName: string,
  variables: TemplateVariables
): Promise<unknown> {
  const templatesDir = resolveTemplatesDir();
  const templatePath = path.join(templatesDir, `${templateName}.yaml.tpl`);

  if (!existsSync(templatePath)) {
    throw new Error(`Template file not found: ${templatePath}`);
  }

  let content = await fs.readFile(templatePath, "utf8");

  // Replace all placeholders (REPLACE_* pattern)
  for (const [key, value] of Object.entries(variables)) {
    const placeholder = `REPLACE_${key.toUpperCase()}`;
    content = content.replace(new RegExp(placeholder, "g"), value);
  }

  // Parse YAML to K8s object
  return k8s.loadYaml(content);
}

/**
 * Available template names for user namespace bootstrap
 */
export const USER_TEMPLATES = {
  namespace: "namespace",
  resourcequota: "resourcequota",
  limitrange: "limitrange",
  networkPolicyDenyAll: "networkpolicy-deny-all",
  controllerRoleBinding: "controller-rolebinding"
} as const;
