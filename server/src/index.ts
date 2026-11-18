import fs from 'node:fs/promises';
import path from 'node:path';
import { buildApi } from './api.js';
import { isPresetName, loadConfig } from './config.js';
import { Db } from './db.js';
import { EventBus, PERSISTED_EVENTS } from './events.js';
import { createLogger } from './log.js';
import { Recorder } from './media/recorder.js';
import { Snapshots } from './media/snapshots.js';
import { Capture } from './stream/capture.js';
import { MediaMtx } from './stream/mediamtx.js';
import { ProcessRegistry } from './util/registry.js';

async function main(): Promise<void> {
  const cfg = loadConfig();
  const log = createLogger(cfg.logLevel);

  for (const d of ['', 'recordings', 'snapshots']) {
    await fs.mkdir(path.join(cfg.storageDir, d), { recursive: true });
  }

  // Kill ffmpeg/mediamtx left running by a previous crash (they would hold the camera/ports).
  const registry = new ProcessRegistry(path.join(cfg.storageDir, 'pids.json'));
  await registry.killOrphans(log);

  const db = new Db(path.join(cfg.storageDir, 'nvr.db'));
  const bus = new EventBus();
  bus.on((ev) => {
    if (PERSISTED_EVENTS.has(ev.type)) db.insertEvent(ev.type, ev.ts, ev);
    if (ev.type === 'preset.changed') db.setSetting('preset', ev.preset);
    log.info({ event: ev.type }, 'event');
  });

  const savedPreset = db.getSetting('preset');
  const preset = isPresetName(savedPreset) ? savedPreset : cfg.camera.defaultPreset;

  const mtx = new MediaMtx(cfg, log, registry);
  const capture = new Capture(cfg, mtx, bus, log, registry, preset);
  const recorder = new Recorder(cfg, db, capture, bus, log, registry);
  const snapshots = new Snapshots(cfg, db, capture, bus, log);

  // The API must be up first: MediaMTX asks it to authorize every publish/read.
  const app = await buildApi({ cfg, db, bus, capture, recorder, snapshots, log });
  await app.listen({ host: cfg.host, port: cfg.port });

  mtx.start();
  if (!(await mtx.waitApi(10_000))) log.warn('MediaMTX API not reachable yet, continuing');
  capture.start();
  await recorder.recoverOrphans();
  log.info(
    { api: `http://localhost:${cfg.port}/api`, live: `http://localhost:${cfg.webrtcPort}/${cfg.streamPath}`, preset },
    'NVR server ready',
  );

  let stopping = false;
  const shutdown = async (signal: string) => {
    if (stopping) return;
    stopping = true;
    log.info({ signal }, 'shutting down');
    try {
      await recorder.stop();
      await recorder.drain();
      await app.close();
      await capture.stop();
      await mtx.stop();
      db.close();
    } catch (err) {
      log.error({ err }, 'error during shutdown');
    }
    process.exit(0);
  };
  for (const sig of ['SIGINT', 'SIGTERM', 'SIGBREAK'] as const) {
    process.on(sig, () => void shutdown(sig));
  }
}

main().catch((err: unknown) => {
  console.error(err);
  process.exit(1);
});
