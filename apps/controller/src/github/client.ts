import { HttpError } from "../http/errors.js";

const DEFAULT_WORKFLOW = "panel-build.yml";

type RepoInfo = { owner: string; repo: string };

function normalizeRepoPath(path: string): string {
  return path.replace(/\.git$/i, "").replace(/^\/+|\/+$/g, "");
}

export function parseRepo(value: string): RepoInfo {
  const trimmed = value.trim();
  if (!trimmed) {
    throw new HttpError(400, "repo is required.");
  }
  if (trimmed.includes("github.com")) {
    try {
      const url = new URL(trimmed);
      const normalized = normalizeRepoPath(url.pathname);
      const [owner, repo] = normalized.split("/");
      if (!owner || !repo) throw new Error("invalid");
      return { owner, repo };
    } catch {
      throw new HttpError(400, "Invalid GitHub repo URL.");
    }
  }
  const normalized = normalizeRepoPath(trimmed);
  const [owner, repo] = normalized.split("/");
  if (!owner || !repo) {
    throw new HttpError(400, "Repo must be in owner/repo format.");
  }
  return { owner, repo };
}

export function resolveWorkflow(value?: string): string {
  const workflow = value?.trim();
  return workflow || DEFAULT_WORKFLOW;
}

export async function dispatchWorkflow(options: {
  token: string;
  repo: RepoInfo;
  ref: string;
  workflow: string;
  inputs?: Record<string, string>;
}): Promise<void> {
  const { token, repo, ref, workflow } = options;
  const url = `https://api.github.com/repos/${repo.owner}/${repo.repo}/actions/workflows/${encodeURIComponent(
    workflow
  )}/dispatches`;

  const response = await fetch(url, {
    method: "POST",
    headers: {
      Accept: "application/vnd.github+json",
      "X-GitHub-Api-Version": "2022-11-28",
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json"
    },
    body: JSON.stringify({
      ref,
      inputs: options.inputs ?? {}
    })
  });

  if (!response.ok) {
    const text = await response.text().catch(() => "");
    throw new HttpError(502, `GitHub dispatch failed (${response.status}): ${text}`);
  }
}
