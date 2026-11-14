import fs from 'node:fs';
import path from 'node:path';
import type { Logger } from '../log.js';
import { killTree, processName } from './proc.js';

/**
 * Remembers PIDs of child processes we spawned (in a JSON file), so that after a
 * crash of this service the next start can kill orphans that still hold the camera.
 */
export class ProcessRegistry {
  private readonly pids = new Map<number, string>();

  constructor(private readonly file: string) {}

  add(pid: number, command: string): void {
    this.pids.set(pid, path.basename(command).toLowerCase().replace(/\.exe$/, ''));
    this.save();
  }

  remove(pid: number): void {
    if (this.pids.delete(pid)) this.save();
  }

  private save(): void {
    fs.writeFileSync(this.file, JSON.stringify(Object.fromEntries(this.pids)));
  }

  async killOrphans(log: Logger): Promise<void> {
    if (!fs.existsSync(this.file)) return;
    let old: Record<string, string> = {};
    try {
      old = JSON.parse(fs.readFileSync(this.file, 'utf8')) as Record<string, string>;
    } catch {
      /* corrupt file: ignore */
    }
    for (const [pidStr, exe] of Object.entries(old)) {
      const pid = Number(pidStr);
      const name = await processName(pid);
      // Only kill if the PID still belongs to the same executable (guards against PID reuse).
      if (name && name.toLowerCase().replace(/\.exe$/, '') === exe) {
        log.warn({ pid, exe }, 'killing orphaned child process from previous run');
        killTree(pid);
      }
    }
    this.pids.clear();
    this.save();
  }
}
