import { PRESETS, type Config, type PresetName } from '../config.js';
import type { EventBus } from '../events.js';
import type { Logger } from '../log.js';
import type { ProcessRegistry } from '../util/registry.js';
import { stopFfmpeg } from '../util/proc.js';
import { Supervisor } from '../util/supervisor.js';
import { sleep } from '../util/time.js';
import type { MediaMtx } from './mediamtx.js';

/**
 * idle     – camera and encoder are off (on-demand mode, nobody needs the stream)
 * starting – capture process launched, stream not published yet
 * live     – stream is published in MediaMTX
 * offline  – capture should be running but the stream isn't coming up (camera unplugged, …)
 */
export type CameraState = 'idle' | 'starting' | 'live' | 'offline';

/** How long a (re)started capture may take before it counts as offline. */
const START_GRACE_MS = 15_000;

/**
 * Owns the camera: one FFmpeg process captures video+audio from DirectShow,
 * encodes H.264 (NVENC or x264) + Opus, and publishes to MediaMTX over RTSP.
 * Everything else (live view, recording, snapshots) reads from MediaMTX.
 *
 * On-demand mode (default): the process only runs while something needs the stream.
 * Live view / snapshots call `ensure()`, an active recording holds it with `hold()`,
 * and MediaMTX's reader count keeps it alive while viewers are connected. After
 * `idleSeconds` without any of these, the camera (and its indicator light) turns off.
 */
export class Capture {
  private readonly sup: Supervisor;
  private preset: PresetName;
  private state: CameraState = 'idle';
  private wanted = false;
  private startedAt = 0;
  private liveSince = 0;
  private holds = 0;
  private lastBusy = 0;
  private poll: NodeJS.Timeout | null = null;

  constructor(
    private readonly cfg: Config,
    private readonly mtx: MediaMtx,
    private readonly bus: EventBus,
    private readonly log: Logger,
    registry: ProcessRegistry,
    initialPreset: PresetName,
  ) {
    this.preset = initialPreset;
    this.sup = new Supervisor({
      name: 'capture',
      command: cfg.ffmpegPath,
      args: () => this.buildArgs(),
      log,
      registry,
      gracefulStop: (c) => void stopFfmpeg(c),
    });
  }

  get currentPreset(): PresetName {
    return this.preset;
  }

  get cameraState(): CameraState {
    return this.state;
  }

  get isOnline(): boolean {
    return this.state === 'live';
  }

  /** How long the stream has been live (0 if it isn't). */
  get liveForMs(): number {
    return this.state === 'live' ? Date.now() - this.liveSince : 0;
  }

  start(): void {
    if (!this.cfg.camera.onDemand) this.activate();
    this.poll = setInterval(() => void this.tick(), 2000);
  }

  async stop(): Promise<void> {
    if (this.poll) clearInterval(this.poll);
    this.poll = null;
    this.wanted = false;
    await this.sup.stop();
  }

  get info() {
    return {
      state: this.state,
      preset: this.preset,
      onDemand: this.cfg.camera.onDemand,
      running: this.sup.running,
      since: this.sup.startedAt,
      crashes: this.sup.crashes,
      lastError: this.sup.crashes ? (this.sup.lastOutput.at(-1) ?? null) : null,
    };
  }

  /** Restart the capture process (e.g. camera stuck); no-op while the camera is idle. */
  async restart(): Promise<void> {
    if (!this.wanted) return;
    this.log.info('camera restart requested');
    this.startedAt = Date.now();
    this.lastBusy = Date.now();
    await this.sup.restart();
  }

  /** Make sure the stream is live (starting the camera if needed). */
  async ensure(timeoutMs = 15_000): Promise<boolean> {
    this.activate();
    const end = Date.now() + timeoutMs;
    while (Date.now() < end) {
      this.lastBusy = Date.now();
      if (await this.mtx.isStreamReady()) {
        this.markLive();
        return true;
      }
      this.activate(); // in case an idle shutdown raced with this call
      await sleep(300);
    }
    return false;
  }

  /** Keep the camera on until the returned function is called (e.g. while recording). */
  hold(): () => void {
    this.holds++;
    this.activate();
    let released = false;
    return () => {
      if (released) return;
      released = true;
      this.holds--;
      this.lastBusy = Date.now();
    };
  }

  /** Switch quality: restarts the capture process if running (live view drops for ~1-2s). */
  async setPreset(preset: PresetName): Promise<void> {
    if (preset === this.preset) return;
    this.preset = preset;
    this.bus.emit({ type: 'preset.changed', preset });
    if (!this.wanted) return; // idle: the next start uses the new preset
    this.startedAt = Date.now();
    this.lastBusy = Date.now();
    await this.sup.restart();
  }

  private activate(): void {
    this.lastBusy = Date.now();
    if (this.wanted) return;
    this.wanted = true;
    this.startedAt = Date.now();
    this.sup.start();
    this.setState('starting');
  }

  private async deactivate(): Promise<void> {
    if (!this.wanted) return;
    this.wanted = false;
    this.log.info({ idleSeconds: this.cfg.camera.idleSeconds }, 'nobody is using the camera, turning it off');
    await this.sup.stop();
    if (!this.wanted) this.setState('idle'); // unless something asked for it again meanwhile
  }

  private markLive(): void {
    if (this.state === 'live') return;
    this.liveSince = Date.now();
    this.setState('live');
  }

  private async tick(): Promise<void> {
    if (!this.wanted) return;
    const info = await this.mtx.pathInfo();
    if (!this.wanted) return;
    const now = Date.now();
    if (info.readers > 0 || this.holds > 0) this.lastBusy = now;

    if (info.ready) this.markLive();
    else this.setState(now - this.startedAt < START_GRACE_MS ? 'starting' : 'offline');

    const idleMs = this.cfg.camera.idleSeconds * 1000;
    if (this.cfg.camera.onDemand && this.holds === 0 && info.readers === 0 && now - this.lastBusy > idleMs) {
      await this.deactivate();
    }
  }

  private setState(s: CameraState): void {
    if (s === this.state) return;
    this.state = s;
    switch (s) {
      case 'live':
        this.bus.emit({ type: 'camera.online' });
        break;
      case 'offline':
        this.bus.emit({ type: 'camera.offline', reason: this.sup.lastOutput.at(-1) });
        break;
      case 'idle':
        this.bus.emit({ type: 'camera.idle' });
        break;
      case 'starting':
        this.bus.emit({ type: 'camera.starting' });
        break;
    }
  }

  buildArgs(): string[] {
    const p = PRESETS[this.preset];
    const cam = this.cfg.camera;
    const input = cam.audio ? `video=${cam.video}:audio=${cam.audio}` : `video=${cam.video}`;

    const args = ['-hide_banner', '-nostats', '-loglevel', 'warning'];

    // --- input (DirectShow) ---
    args.push('-f', 'dshow', '-rtbufsize', '256M');
    // Cheap UVC cameras report frame timestamps at the nominal rate (30fps) even when
    // they deliver fewer frames (e.g. ~20fps in low light). That makes video run slower
    // than real time: latency grows and audio drifts. Stamp packets with the PC clock.
    args.push('-use_wallclock_as_timestamps', '1');
    if (cam.inputCodec) args.push('-vcodec', cam.inputCodec);
    args.push('-video_size', p.size, '-framerate', String(cam.inputFps));
    if (cam.audio) args.push('-audio_buffer_size', '50'); // default ~500ms adds latency
    args.push('-i', input);

    // --- output frame rate (camera may only offer 30fps; drop frames for 15fps presets) ---
    args.push('-r', String(p.fps));

    // --- video: low latency, no B-frames (required by WebRTC), 1s GOP ---
    if (cam.encoder === 'nvenc') {
      args.push('-c:v', 'h264_nvenc', '-preset', 'p4', '-tune', 'll', '-rc', 'cbr');
    } else {
      args.push('-c:v', 'libx264', '-preset', 'veryfast', '-tune', 'zerolatency');
    }
    args.push(
      '-profile:v', 'main',
      '-pix_fmt', 'yuv420p',
      '-b:v', p.bitrate, '-maxrate', p.maxrate, '-bufsize', p.bufsize,
      '-bf', '0',
      '-g', String(p.fps), '-keyint_min', String(p.fps),
    );

    // --- audio: Opus for WebRTC (recordings are transcoded to AAC) ---
    if (cam.audio) args.push('-c:a', 'libopus', '-b:a', '64k', '-ar', '48000', '-ac', '1');
    else args.push('-an');

    args.push('-f', 'rtsp', '-rtsp_transport', 'tcp', this.cfg.rtspUrl);
    return args;
  }
}
