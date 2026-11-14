const pad = (n: number, width = 2) => String(n).padStart(width, '0');

/** Local date as YYYY-MM-DD (used for per-day storage folders). */
export function dayDir(ts: number): string {
  const d = new Date(ts);
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}

/** Local timestamp for file names: YYYY-MM-DD_HH-mm-ss[-SSS]. */
export function stamp(ts: number, withMs = false): string {
  const d = new Date(ts);
  const base = `${dayDir(ts)}_${pad(d.getHours())}-${pad(d.getMinutes())}-${pad(d.getSeconds())}`;
  return withMs ? `${base}-${pad(d.getMilliseconds(), 3)}` : base;
}

export const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));
