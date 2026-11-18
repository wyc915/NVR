import type { Config } from '../config.js';
import type { Logger } from '../log.js';
import type { ProcessRegistry } from '../util/registry.js';
import { Supervisor } from '../util/supervisor.js';
import { sleep } from '../util/time.js';

/** Runs MediaMTX and answers "is the camera stream being published?". */
export class MediaMtx {
  private readonly sup: Supervisor;

  constructor(
    private readonly cfg: Config,
    log: Logger,
    registry: ProcessRegistry,
  ) {
    this.sup = new Supervisor({
      name: 'mediamtx',
      command: cfg.mediamtxPath,
      args: () => [cfg.mediamtxConfig],
      log,
      registry,
      // Keep the auth endpoint in sync with our API port (overrides mediamtx.yml).
      env: { MTX_AUTHHTTPADDRESS: `http://127.0.0.1:${cfg.port}/internal/mediamtx/auth` },
    });
  }

  start(): void {
    this.sup.start();
  }

  stop(): Promise<void> {
    return this.sup.stop();
  }

  /** Wait until the MediaMTX control API answers. */
  async waitApi(timeoutMs: number): Promise<boolean> {
    const end = Date.now() + timeoutMs;
    while (Date.now() < end) {
      try {
        const r = await fetch(`${this.cfg.mediamtxApi}/v3/paths/list`, { signal: AbortSignal.timeout(1000) });
        if (r.ok) return true;
      } catch {
        /* not up yet */
      }
      await sleep(300);
    }
    return false;
  }

  /** Is the camera stream published, and how many clients (WebRTC, RTSP) read it. */
  async pathInfo(): Promise<{ ready: boolean; readers: number }> {
    try {
      const r = await fetch(`${this.cfg.mediamtxApi}/v3/paths/get/${this.cfg.streamPath}`, {
        signal: AbortSignal.timeout(2000),
      });
      if (!r.ok) return { ready: false, readers: 0 };
      const j = (await r.json()) as { ready?: boolean; readers?: unknown[] };
      return { ready: j.ready === true, readers: Array.isArray(j.readers) ? j.readers.length : 0 };
    } catch {
      return { ready: false, readers: 0 };
    }
  }

  async isStreamReady(): Promise<boolean> {
    return (await this.pathInfo()).ready;
  }

  async waitStreamReady(timeoutMs: number): Promise<boolean> {
    const end = Date.now() + timeoutMs;
    while (Date.now() < end) {
      if (await this.isStreamReady()) return true;
      await sleep(500);
    }
    return false;
  }
}
