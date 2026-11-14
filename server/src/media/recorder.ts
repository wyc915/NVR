import { randomUUID } from 'node:crypto';
import { spawn, type ChildProcess } from 'node:child_process';
import fs from 'node:fs/promises';
import path from 'node:path';
import type { Config, PresetName } from '../config.js';
import type { Db } from '../db.js';
import { recordingDto } from '../dto.js';
import type { EventBus } from '../events.js';
import type { Logger } from '../log.js';
import type { MediaMtx } from '../stream/mediamtx.js';
import type { Capture } from '../stream/capture.js';
import { run, stopFfmpeg, tailLines } from '../util/proc.js';
import type { ProcessRegistry } from '../util/registry.js';
import { dayDir, sleep, stamp } from '../util/time.js';
import { fileSize, probeDuration, toRel } from './files.js';

interface Session {
  id: string;
  startedAt: number;
  proc: ChildProcess | null;
}

export interface RecordingStatus {
  active: boolean;
  sessionId?: string;
  startedAt?: number;
}

/**
 * Manual recording. While a session is active, an FFmpeg process reads the RTSP
 * stream from MediaMTX and writes a fragmented MP4 (`*.part.mp4`, survives crashes):
 * video is copied as-is, audio is transcoded Opus → AAC so phones can play it.
 *
 * A session is split into segments: a new file starts when the max segment length
 * is reached or when the input stream restarts (e.g. quality preset change).
 * Each finished segment is remuxed to a regular MP4 with +faststart, gets a
 * thumbnail and is added to the database.
 */
export class Recorder {
  private session: Session | null = null;
  private readonly pending = new Set<Promise<void>>();

  constructor(
    private readonly cfg: Config,
    private readonly db: Db,
    private readonly mtx: MediaMtx,
    private readonly capture: Capture,
    private readonly bus: EventBus,
    private readonly log: Logger,
    private readonly registry: ProcessRegistry,
  ) {}

  get status(): RecordingStatus {
    const s = this.session;
    return s ? { active: true, sessionId: s.id, startedAt: s.startedAt } : { active: false };
  }

  start(): RecordingStatus {
    if (this.session) return this.status;
    const s: Session = { id: randomUUID(), startedAt: Date.now(), proc: null };
    this.session = s;
    this.bus.emit({ type: 'recording.started', sessionId: s.id, startedAt: s.startedAt });
    void this.loop(s);
    return this.status;
  }

  async stop(): Promise<RecordingStatus> {
    const s = this.session;
    if (!s) return this.status;
    this.session = null;
    if (s.proc) await stopFfmpeg(s.proc);
    this.bus.emit({ type: 'recording.stopped', sessionId: s.id });
    return this.status;
  }

  /** Wait for all segments still being finalized (used on shutdown). */
  async drain(): Promise<void> {
    await Promise.allSettled([...this.pending]);
  }

  /** Finalize `*.part.mp4` files left behind by a crash or power loss. */
  async recoverOrphans(): Promise<void> {
    const root = path.join(this.cfg.storageDir, 'recordings');
    let entries: string[] = [];
    try {
      entries = (await fs.readdir(root, { recursive: true })) as string[];
    } catch {
      return;
    }
    for (const rel of entries.filter((e) => e.endsWith('.part.mp4'))) {
      const abs = path.join(root, rel);
      const st = await fs.stat(abs);
      this.log.warn({ file: abs }, 'recovering unfinished recording');
      this.track(this.finalize(abs, st.birthtimeMs, null, null));
    }
  }

  private track(p: Promise<void>): void {
    this.pending.add(p);
    void p.finally(() => this.pending.delete(p));
  }

  private async loop(s: Session): Promise<void> {
    while (this.session === s) {
      if (!(await this.mtx.waitStreamReady(10_000))) {
        if (this.session === s) this.log.warn('recording: waiting for camera stream');
        continue;
      }
      if (this.session !== s) return;

      const startedAt = Date.now();
      const preset = this.capture.currentPreset;
      const dir = path.join(this.cfg.storageDir, 'recordings', dayDir(startedAt));
      await fs.mkdir(dir, { recursive: true });
      if (this.session !== s) return;
      const partPath = path.join(dir, `${stamp(startedAt)}.part.mp4`);

      const args = [
        '-hide_banner', '-nostats', '-loglevel', 'warning',
        '-rtsp_transport', 'tcp', '-timeout', '5000000',
        '-i', this.cfg.rtspUrl,
        '-map', '0',
        '-c:v', 'copy',
        '-c:a', 'aac', '-b:a', this.cfg.recording.audioBitrate,
        '-t', String(this.cfg.recording.maxSegmentMinutes * 60),
        '-f', 'mp4', '-movflags', '+frag_keyframe+empty_moov+default_base_moof',
        '-y', partPath,
      ];
      const proc = spawn(this.cfg.ffmpegPath, args, { stdio: ['pipe', 'ignore', 'pipe'], windowsHide: true });
      if (proc.pid) this.registry.add(proc.pid, this.cfg.ffmpegPath);
      s.proc = proc;
      const tail = tailLines(proc.stderr, 10);
      this.log.info({ file: partPath, preset }, 'recording segment started');

      const code = await new Promise<number | null>((resolve) => {
        proc.on('error', () => resolve(null));
        proc.on('close', (c) => resolve(c));
      });
      if (proc.pid) this.registry.remove(proc.pid);
      s.proc = null;
      this.track(this.finalize(partPath, startedAt, preset, s.id));

      if (this.session === s) {
        // Still recording: either max length reached (code 0) or input dropped.
        if (code !== 0) {
          this.log.warn({ code, output: tail.slice(-3) }, 'recording segment ended unexpectedly, continuing');
        }
        await sleep(1000);
      }
    }
  }

  private async finalize(
    partPath: string,
    startedAt: number,
    preset: PresetName | null,
    sessionId: string | null,
  ): Promise<void> {
    try {
      const partSize = await fileSize(partPath);
      if (partSize === null) return;
      if (partSize < 4096) {
        await fs.rm(partPath, { force: true });
        return;
      }
      const finalPath = partPath.replace(/\.part\.mp4$/, '.mp4');
      const remux = await run(
        this.cfg.ffmpegPath,
        ['-hide_banner', '-loglevel', 'error', '-y', '-i', partPath, '-map', '0', '-c', 'copy', '-movflags', '+faststart', finalPath],
        5 * 60_000,
      );
      if (remux.code !== 0) {
        this.log.error({ file: partPath, err: remux.stderr.slice(-500) }, 'remux failed, keeping .part.mp4');
        this.bus.emit({ type: 'recording.error', message: `remux failed: ${path.basename(partPath)}` });
        return;
      }
      await fs.rm(partPath, { force: true });

      const duration = await probeDuration(this.cfg, finalPath);
      const thumbPath = finalPath.replace(/\.mp4$/, '.jpg');
      const thumb = await run(
        this.cfg.ffmpegPath,
        ['-hide_banner', '-loglevel', 'error', '-y', '-ss', String(Math.min(1, duration / 2)), '-i', finalPath,
          '-frames:v', '1', '-vf', 'scale=320:-2', '-q:v', '4', thumbPath],
        30_000,
      );

      const row = this.db.insertRecording({
        id: randomUUID(),
        session_id: sessionId,
        path: toRel(this.cfg, finalPath),
        thumb_path: thumb.code === 0 ? toRel(this.cfg, thumbPath) : null,
        started_at: Math.round(startedAt),
        ended_at: Math.round(startedAt + duration * 1000),
        duration,
        size: await fileSize(finalPath),
        preset,
      });
      this.log.info({ file: finalPath, duration: duration.toFixed(1) }, 'recording saved');
      this.bus.emit({ type: 'recording.saved', recording: recordingDto(row) });
    } catch (err) {
      this.log.error({ err, file: partPath }, 'finalize failed');
    }
  }
}
