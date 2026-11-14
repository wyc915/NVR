import { randomUUID } from 'node:crypto';
import fs from 'node:fs/promises';
import path from 'node:path';
import type { Config } from '../config.js';
import type { Db } from '../db.js';
import { snapshotDto, type SnapshotDto } from '../dto.js';
import type { EventBus } from '../events.js';
import type { Logger } from '../log.js';
import type { Capture } from '../stream/capture.js';
import type { MediaMtx } from '../stream/mediamtx.js';
import { HttpError } from '../util/errors.js';
import { run } from '../util/proc.js';
import { dayDir, stamp } from '../util/time.js';
import { fileSize, toRel } from './files.js';

/** Grabs one frame from the live stream as a full-size JPG plus a 320px thumbnail. */
export class Snapshots {
  constructor(
    private readonly cfg: Config,
    private readonly db: Db,
    private readonly mtx: MediaMtx,
    private readonly capture: Capture,
    private readonly bus: EventBus,
    private readonly log: Logger,
  ) {}

  private inFlight: Promise<SnapshotDto> | null = null;

  /** One FFmpeg at a time: concurrent requests share the snapshot being taken. */
  take(): Promise<SnapshotDto> {
    this.inFlight ??= this.doTake().finally(() => {
      this.inFlight = null;
    });
    return this.inFlight;
  }

  private async doTake(): Promise<SnapshotDto> {
    if (!(await this.mtx.isStreamReady())) throw new HttpError(503, 'camera stream is offline');

    const now = Date.now();
    const dir = path.join(this.cfg.storageDir, 'snapshots', dayDir(now));
    await fs.mkdir(dir, { recursive: true });
    const base = path.join(dir, stamp(now, true));
    const full = `${base}.jpg`;
    const thumb = `${base}.thumb.jpg`;

    const r = await run(
      this.cfg.ffmpegPath,
      [
        '-hide_banner', '-loglevel', 'error', '-y',
        // Skip stream analysis (codec info comes from the RTSP SDP): ~3s → ~1s,
        // the rest is waiting for the next keyframe (1s GOP).
        '-analyzeduration', '0', '-probesize', '32768', '-fflags', 'nobuffer',
        '-rtsp_transport', 'tcp', '-timeout', '5000000',
        '-i', this.cfg.rtspUrl,
        '-an',
        '-filter_complex', '[0:v]split=2[full][t];[t]scale=320:-2[thumb]',
        '-map', '[full]', '-frames:v', '1', '-q:v', '2', full,
        '-map', '[thumb]', '-frames:v', '1', '-q:v', '5', thumb,
      ],
      15_000,
    );
    const size = await fileSize(full);
    if (r.code !== 0 || !size) {
      this.log.error({ err: r.stderr.slice(-500) }, 'snapshot failed');
      throw new HttpError(500, 'snapshot failed');
    }

    const row = this.db.insertSnapshot({
      id: randomUUID(),
      path: toRel(this.cfg, full),
      thumb_path: (await fileSize(thumb)) ? toRel(this.cfg, thumb) : null,
      taken_at: now,
      size,
      preset: this.capture.currentPreset,
    });
    const dto = snapshotDto(row);
    this.bus.emit({ type: 'snapshot.saved', snapshot: dto });
    return dto;
  }
}
