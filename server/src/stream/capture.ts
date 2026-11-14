import { PRESETS, type Config, type PresetName } from '../config.js';
import type { EventBus } from '../events.js';
import type { Logger } from '../log.js';
import type { ProcessRegistry } from '../util/registry.js';
import { stopFfmpeg } from '../util/proc.js';
import { Supervisor } from '../util/supervisor.js';
import type { MediaMtx } from './mediamtx.js';

/**
 * Owns the camera: one FFmpeg process captures video+audio from DirectShow,
 * encodes H.264 (NVENC or x264) + Opus, and publishes to MediaMTX over RTSP.
 * Everything else (live view, recording, snapshots) reads from MediaMTX.
 */
export class Capture {
  private readonly sup: Supervisor;
  private preset: PresetName;
  private online = false;
  private poll: NodeJS.Timeout | null = null;

  constructor(
    private readonly cfg: Config,
    private readonly mtx: MediaMtx,
    private readonly bus: EventBus,
    log: Logger,
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

  get isOnline(): boolean {
    return this.online;
  }

  start(): void {
    this.sup.start();
    this.poll = setInterval(() => void this.checkOnline(), 2000);
  }

  async stop(): Promise<void> {
    if (this.poll) clearInterval(this.poll);
    this.poll = null;
    await this.sup.stop();
  }

  /** Switch quality: restarts the capture process (live view drops for ~1-2s). */
  async setPreset(preset: PresetName): Promise<void> {
    if (preset === this.preset) return;
    this.preset = preset;
    this.bus.emit({ type: 'preset.changed', preset });
    await this.sup.restart();
  }

  private async checkOnline(): Promise<void> {
    const ready = await this.mtx.isStreamReady();
    if (ready === this.online) return;
    this.online = ready;
    if (ready) this.bus.emit({ type: 'camera.online' });
    else this.bus.emit({ type: 'camera.offline', reason: this.sup.lastOutput.at(-1) });
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
