import { spawn, type ChildProcess } from 'node:child_process';

/** Kill a process and all of its children (Windows needs taskkill /T). */
export function killTree(pid: number | undefined): void {
  if (!pid) return;
  if (process.platform === 'win32') {
    spawn('taskkill', ['/PID', String(pid), '/T', '/F'], { stdio: 'ignore', windowsHide: true }).on(
      'error',
      () => {},
    );
  } else {
    try {
      process.kill(pid, 'SIGKILL');
    } catch {
      /* already gone */
    }
  }
}

/** Image name of a running process (e.g. "ffmpeg.exe"), or null if not running. */
export async function processName(pid: number): Promise<string | null> {
  if (process.platform !== 'win32') return null;
  const r = await run('tasklist', ['/FI', `PID eq ${pid}`, '/FO', 'CSV', '/NH'], 10_000);
  const m = /^"([^"]+)","(\d+)"/m.exec(r.stdout);
  return m && Number(m[2]) === pid ? m[1] : null;
}

export interface RunResult {
  code: number | null;
  stdout: string;
  stderr: string;
}

/** Run a short-lived command to completion, capturing output. */
export function run(cmd: string, args: string[], timeoutMs = 60_000): Promise<RunResult> {
  return new Promise((resolve) => {
    const child = spawn(cmd, args, { stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true });
    let stdout = '';
    let stderr = '';
    child.stdout.setEncoding('utf8').on('data', (d: string) => (stdout += d));
    child.stderr.setEncoding('utf8').on('data', (d: string) => (stderr += d));
    const timer = setTimeout(() => killTree(child.pid), timeoutMs);
    let done = false;
    const finish = (code: number | null) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      resolve({ code, stdout, stderr });
    };
    child.on('error', (e) => {
      stderr += String(e);
      finish(null);
    });
    child.on('close', (code) => finish(code));
  });
}

/** Keeps the last N lines written to a stream. */
export function tailLines(stream: NodeJS.ReadableStream | null, max = 20, onLine?: (l: string) => void) {
  const lines: string[] = [];
  let buf = '';
  stream?.setEncoding('utf8');
  stream?.on('data', (chunk: string) => {
    buf += chunk;
    const parts = buf.split(/\r?\n|\r/);
    buf = parts.pop() ?? '';
    for (const l of parts) {
      if (!l.trim()) continue;
      lines.push(l);
      if (lines.length > max) lines.shift();
      onLine?.(l);
    }
  });
  return lines;
}

/** Ask ffmpeg to quit cleanly ("q" on stdin), force-kill after timeout. Resolves on exit. */
export function stopFfmpeg(child: ChildProcess, timeoutMs = 5000): Promise<void> {
  return new Promise((resolve) => {
    if (child.exitCode !== null || child.signalCode !== null) return resolve();
    const hard = setTimeout(() => killTree(child.pid), timeoutMs);
    const giveUp = setTimeout(() => resolve(), timeoutMs + 3000);
    child.once('close', () => {
      clearTimeout(hard);
      clearTimeout(giveUp);
      resolve();
    });
    try {
      child.stdin?.write('q');
      child.stdin?.end();
    } catch {
      killTree(child.pid);
    }
  });
}
