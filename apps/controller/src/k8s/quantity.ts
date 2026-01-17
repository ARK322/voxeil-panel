export function parseCpuToNumber(value: string | undefined): number | null {
  if (!value) return null;
  const trimmed = value.trim();
  if (!trimmed) return null;
  if (trimmed.endsWith("m")) {
    const number = Number(trimmed.slice(0, -1));
    return Number.isFinite(number) ? number / 1000 : null;
  }
  const number = Number(trimmed);
  return Number.isFinite(number) ? number : null;
}

export function parseGiToNumber(value: string | undefined): number | null {
  if (!value) return null;
  const trimmed = value.trim();
  if (!trimmed) return null;
  if (trimmed.endsWith("Gi")) {
    const number = Number(trimmed.slice(0, -2));
    return Number.isFinite(number) ? number : null;
  }
  if (trimmed.endsWith("Mi")) {
    const number = Number(trimmed.slice(0, -2));
    return Number.isFinite(number) ? number / 1024 : null;
  }
  const number = Number(trimmed);
  return Number.isFinite(number) ? number : null;
}
