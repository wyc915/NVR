import fs from 'node:fs/promises';
import path from 'node:path';
import type { Config } from '../config.js';
import { run } from '../util/proc.js';

/** Path relative to storageDir with forward slashes (what we store in the DB). */
export const toRel = (cfg: Config, abs: string) => path.relative(cfg.storageDir, abs).split(path.sep).join('/');

export const toAbs = (cfg: Config, rel: string) => path.join(cfg.storageDir, ...rel.split('/'));

export async function fileSize(p: string): Promise<number | null> {
  try {
    return (await fs.stat(p)).size;
  } catch {
    return null;
  }
}

export async function probeDuration(cfg: Config, file: string): Promise<number> {
  const r = await run(cfg.ffprobePath, ['-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', file], 30_000);
  const n = parseFloat(r.stdout.trim());
  return Number.isFinite(n) ? n : 0;
}

/** Remove the file and its parent day folder if that becomes empty. */
export async function removeFile(p: string): Promise<void> {
  await fs.rm(p, { force: true });
  const dir = path.dirname(p);
  try {
    if ((await fs.readdir(dir)).length === 0) await fs.rmdir(dir);
  } catch {
    /* ignore */
  }
}

export async function diskUsage(dir: string): Promise<{ free: number; total: number }> {
  const s = await fs.statfs(dir);
  return { free: s.bavail * s.bsize, total: s.blocks * s.bsize };
}
