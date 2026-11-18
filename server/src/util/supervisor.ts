import { spawn, type ChildProcess } from 'node:child_process';
import { EventEmitter } from 'node:events';
import type { Logger } from '../log.js';
import { killTree, tailLines } from './proc.js';
import type { ProcessRegistry } from './registry.js';

export interface SupervisorOptions {
  name: string;
  command: string;
  /** Called on every (re)start so arguments can change, e.g. after a preset switch. */
  args: () => string[];
  log: Logger;
  registry: ProcessRegistry;
  /** How to ask the process to stop; default is a hard kill. */
  gracefulStop?: (child: ChildProcess) => void;
  /** Extra environment variables. */
  env?: Record<string, string>;
}

/**
 * Keeps a long-running child process alive: restarts it with exponential
 * backoff (1s → 30s) when it exits unexpectedly.
 */
export class Supervisor extends EventEmitter {
  private child: ChildProcess | null = null;
  private wanted = false;
  private backoffMs = 1000;
  private restartTimer: NodeJS.Timeout | null = null;
  private tail: string[] = [];
  /** Unexpected exits since the server started. */
  crashes = 0;
  startedAt: number | null = null;

  constructor(private readonly opts: SupervisorOptions) {
    super();
  }

  get running(): boolean {
    return this.child !== null;
  }

  /** Last stderr/stdout lines of the current or most recent run. */
  get lastOutput(): string[] {
    return this.tail.slice();
  }

  start(): void {
    this.wanted = true;
    if (!this.child && !this.restartTimer) this.spawnChild();
  }

  async stop(timeoutMs = 5000): Promise<void> {
    this.wanted = false;
    if (this.restartTimer) {
      clearTimeout(this.restartTimer);
      this.restartTimer = null;
    }
    const c = this.child;
    if (!c) return;
    await new Promise<void>((resolve) => {
      const hard = setTimeout(() => killTree(c.pid), timeoutMs);
      const giveUp = setTimeout(resolve, timeoutMs + 3000);
      c.once('close', () => {
        clearTimeout(hard);
        clearTimeout(giveUp);
        resolve();
      });
      if (this.opts.gracefulStop) this.opts.gracefulStop(c);
      else killTree(c.pid);
    });
  }

  async restart(): Promise<void> {
    await this.stop();
    this.backoffMs = 1000;
    this.start();
  }

  private spawnChild(): void {
    const { name, command, log, registry } = this.opts;
    const args = this.opts.args();
    log.info({ proc: name }, 'starting process');
    log.debug({ proc: name, command, args }, 'process command line');

    const startedAt = Date.now();
    const child = spawn(command, args, {
      stdio: ['pipe', 'pipe', 'pipe'],
      windowsHide: true,
      env: this.opts.env ? { ...process.env, ...this.opts.env } : process.env,
    });
    this.child = child;
    this.startedAt = startedAt;
    const onLine = (l: string) => log.debug({ proc: name }, l);
    const out = tailLines(child.stdout, 10, onLine);
    const err = tailLines(child.stderr, 10, onLine);
    this.tail = [];
    if (child.pid) registry.add(child.pid, command);

    let ended = false;
    const onEnd = (code: number | null, spawnErr?: Error) => {
      if (ended) return;
      ended = true;
      if (child.pid) registry.remove(child.pid);
      this.child = null;
      this.startedAt = null;
      this.tail = [...out, ...err];
      this.emit('exit', code);

      if (!this.wanted) {
        log.info({ proc: name, code }, 'process stopped');
        return;
      }
      this.crashes++;
      if (Date.now() - startedAt > 15_000) this.backoffMs = 1000;
      const delay = this.backoffMs;
      this.backoffMs = Math.min(this.backoffMs * 2, 30_000);
      log.warn(
        { proc: name, code, err: spawnErr?.message, output: this.tail.slice(-3), retryInMs: delay },
        'process exited unexpectedly, restarting',
      );
      this.restartTimer = setTimeout(() => {
        this.restartTimer = null;
        if (this.wanted) this.spawnChild();
      }, delay);
    };
    child.on('error', (e) => onEnd(null, e));
    child.on('close', (code) => onEnd(code));
  }
}
