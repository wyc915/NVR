import fastifyStatic from '@fastify/static';
import fastifyWebsocket from '@fastify/websocket';
import Fastify from 'fastify';
import fs from 'node:fs';
import path from 'node:path';
import { PRESETS, type Config, type PresetName } from './config.js';
import type { Db } from './db.js';
import { recordingDto, snapshotDto } from './dto.js';
import type { EventBus } from './events.js';
import type { Logger } from './log.js';
import { diskUsage, removeFile, toAbs } from './media/files.js';
import type { Recorder } from './media/recorder.js';
import type { Snapshots } from './media/snapshots.js';
import { FailureLimiter, isLoopback, NetworkAllowlist, safeEqual, UrlSigner } from './security.js';
import type { Capture } from './stream/capture.js';
import { HttpError } from './util/errors.js';

export interface ApiDeps {
  cfg: Config;
  db: Db;
  bus: EventBus;
  capture: Capture;
  recorder: Recorder;
  snapshots: Snapshots;
  log: Logger;
}

/** Payload MediaMTX POSTs to authHTTPAddress for every publish/read/api action. */
interface MediaMtxAuthRequest {
  user?: string;
  password?: string;
  token?: string;
  ip?: string;
  action?: string;
  path?: string;
  protocol?: string;
}

const listQuery = {
  type: 'object',
  properties: {
    limit: { type: 'integer', minimum: 1, maximum: 500, default: 50 },
    before: { type: 'integer' },
  },
} as const;

const idParams = {
  type: 'object',
  required: ['id'],
  properties: { id: { type: 'string', pattern: '^[0-9a-f-]{36}$' } },
} as const;

type ListQuery = { limit: number; before?: number };
type IdParams = { id: string };

export async function buildApi(deps: ApiDeps) {
  const { cfg, db, bus, capture, recorder, snapshots, log } = deps;
  // Fastify's own logging (per-request lines) only at warn level; our modules log via `log`.
  const app = Fastify({
    loggerInstance: log.child({ mod: 'http' }, { level: 'warn' }),
    // `tailscale serve` (HTTPS for iPhone Safari) proxies from loopback and sends the real
    // client IP in X-Forwarded-For. Trust that header only from loopback, so the
    // allowlist and failure limiter see the phone's Tailscale IP, not 127.0.0.1.
    // Direct remote clients can't spoof it: their socket address isn't loopback.
    trustProxy: ['127.0.0.1', '::1'],
  });

  // Be lenient with bodies: command endpoints (record/start, snapshot, ...) take no body,
  // but some clients still send a Content-Type (or an empty JSON body).
  app.removeContentTypeParser('application/json');
  app.addContentTypeParser('application/json', { parseAs: 'string' }, (_req, body, done) => {
    const text = String(body).trim();
    if (!text) return done(null, undefined);
    try {
      done(null, JSON.parse(text));
    } catch {
      done(new HttpError(400, 'invalid JSON body'), undefined);
    }
  });
  // WebRTC SDP offers for the WHEP proxy.
  app.addContentTypeParser('application/sdp', { parseAs: 'string', bodyLimit: 64 * 1024 }, (_req, body, done) =>
    done(null, String(body)),
  );
  app.addContentTypeParser('*', { parseAs: 'string' }, (_req, _body, done) => done(null, undefined));

  const allowlist = new NetworkAllowlist(cfg.allowedNetworks);
  const signer = new UrlSigner(cfg.token);
  const limiter = new FailureLimiter();

  // 1) Network allowlist: drop anything not from loopback / Tailscale / configured LAN.
  app.addHook('onRequest', async (req, reply) => {
    if (!allowlist.allows(req.ip)) {
      log.warn({ ip: req.ip, url: req.url.split('?')[0] }, 'rejected request from non-allowed network');
      return reply.code(403).send({ error: 'forbidden' });
    }
  });

  // 2) Security headers on every response.
  app.addHook('onSend', async (_req, reply) => {
    reply.header('X-Content-Type-Options', 'nosniff');
    reply.header('Referrer-Policy', 'no-referrer');
    reply.header('X-Frame-Options', 'DENY');
  });

  // 3) Never leak internal error details (paths, stack messages) to clients.
  app.setErrorHandler((err: Error & { statusCode?: number; validation?: unknown }, req, reply) => {
    const code = err.statusCode && err.statusCode >= 400 ? err.statusCode : 500;
    if (code >= 500) {
      log.error({ err, url: req.url.split('?')[0] }, 'request failed');
      return reply.code(code).send({ error: 'internal error' });
    }
    return reply.code(code).send({ error: err.message });
  });

  // No CORS: the web app is served from this same origin, native apps don't need it.
  await app.register(fastifyStatic, { root: cfg.storageDir, serve: false });
  // The web app (app shell only, no secrets; the API below still needs the token).
  if (fs.existsSync(path.join(cfg.webDir, 'index.html'))) {
    const noCache = /(?:^|[\\/])(?:index\.html|flutter_service_worker\.js|flutter_bootstrap\.js|version\.json|manifest\.json)$/;
    await app.register(fastifyStatic, {
      root: cfg.webDir,
      prefix: '/',
      decorateReply: false,
      setHeaders: (res, file) => {
        if (noCache.test(file)) res.header('Cache-Control', 'no-cache');
      },
    });
  } else {
    log.info({ webDir: cfg.webDir }, 'web app not built, not serving it');
  }
  await app.register(fastifyWebsocket, { options: { maxPayload: 1024 } });

  // 4) Auth for /api/*:
  //    - "Authorization: Bearer <token>" for everything, or
  //    - a signed URL (?exp=&sig=) for GET of media files / thumbnails / the event WebSocket.
  //    Repeated failures from one IP get it blocked for a while.
  app.addHook('onRequest', async (req, reply) => {
    if (!req.url.startsWith('/api/')) return;
    if (limiter.isBlocked(req.ip)) return reply.code(429).send({ error: 'too many failed attempts' });

    const header = req.headers.authorization;
    if (header?.startsWith('Bearer ') && safeEqual(header.slice(7), cfg.token)) return;

    const q = req.query as Record<string, unknown>;
    const path = req.url.split('?')[0];
    if (req.method === 'GET' && signer.verify(path, q.exp, q.sig)) return;

    if (limiter.fail(req.ip)) log.warn({ ip: req.ip }, 'too many failed auth attempts, blocking IP');
    return reply.code(401).send({ error: 'unauthorized' });
  });

  // 5) MediaMTX delegates auth here (authMethod: http). Local processes (our FFmpeg
  //    capture/recorder/snapshot) may do anything; remote clients may only *read* the
  //    camera stream, with the API token as Bearer token or password.
  app.post<{ Body: MediaMtxAuthRequest }>('/internal/mediamtx/auth', async (req, reply) => {
    if (!isLoopback(req.ip)) return reply.code(403).send();
    const b = req.body ?? {};
    const clientIp = b.ip ?? '';
    if (isLoopback(clientIp)) return reply.code(200).send();

    const secret = b.token || b.password || '';
    if (
      b.action === 'read' &&
      b.path === cfg.streamPath &&
      allowlist.allows(clientIp) &&
      !limiter.isBlocked(clientIp) &&
      secret &&
      safeEqual(secret, cfg.token)
    ) {
      return reply.code(200).send();
    }
    // MediaMTX first asks without credentials to trigger a 401 challenge; don't count those.
    if (secret && limiter.fail(clientIp)) log.warn({ ip: clientIp }, 'too many failed stream auth attempts');
    return reply.code(401).send();
  });

  const status = async () => ({
    camera: {
      online: capture.isOnline,
      state: capture.cameraState,
      preset: capture.currentPreset,
      presets: Object.keys(PRESETS),
      encoder: cfg.camera.encoder,
    },
    recording: recorder.status,
    disk: await diskUsage(cfg.storageDir),
    live: { whepPath: '/api/live/whep' },
    serverTime: Date.now(),
  });

  // Unauthenticated liveness probe.
  app.get('/health', async () => ({ ok: true }));

  app.get('/api/status', status);

  // --- stream quality ---
  app.post<{ Body: { preset: PresetName } }>(
    '/api/stream/preset',
    {
      schema: {
        body: {
          type: 'object',
          required: ['preset'],
          properties: { preset: { type: 'string', enum: Object.keys(PRESETS) } },
        },
      },
    },
    async (req) => {
      await capture.setPreset(req.body.preset);
      return { preset: capture.currentPreset };
    },
  );

  // --- live view: WHEP signaling proxied to MediaMTX ---
  // Same origin as the API, so it works behind `tailscale serve` (HTTPS) and MediaMTX's
  // port needn't be reachable from outside. The token was checked by the /api/* hook; MediaMTX sees a loopback client.
  // Media (UDP/TCP 8189) still flows directly between the phone and MediaMTX.
  const whepUpstream = `http://127.0.0.1:${cfg.webrtcPort}/${cfg.streamPath}/whep`;
  const sessionParams = {
    type: 'object',
    required: ['session'],
    properties: { session: { type: 'string', pattern: '^[0-9A-Za-z-]{1,64}$' } },
  } as const;

  app.post('/api/live/whep', async (req, reply) => {
    if (typeof req.body !== 'string' || !req.body.startsWith('v=')) throw new HttpError(400, 'SDP offer required');
    // On-demand: switch the camera on and wait for the stream before MediaMTX sees the offer.
    if (!(await capture.ensure())) return reply.code(503).send({ error: 'camera unavailable' });
    const r = await fetch(whepUpstream, {
      method: 'POST',
      headers: { 'Content-Type': 'application/sdp' },
      body: req.body,
      signal: AbortSignal.timeout(10_000),
    });
    const text = await r.text();
    if (r.status !== 201) {
      if (r.status >= 500) log.warn({ status: r.status }, 'WHEP upstream error');
      return reply.code(r.status === 400 || r.status === 404 ? r.status : 502).send({ error: 'stream unavailable' });
    }
    const session = /\/whep\/([0-9A-Za-z-]{1,64})$/.exec(r.headers.get('location') ?? '')?.[1];
    if (session) reply.header('Location', `/api/live/whep/${session}`);
    return reply.code(201).type('application/sdp').send(text);
  });

  app.delete<{ Params: { session: string } }>(
    '/api/live/whep/:session',
    { schema: { params: sessionParams } },
    async (req, reply) => {
      const r = await fetch(`${whepUpstream}/${req.params.session}`, {
        method: 'DELETE',
        signal: AbortSignal.timeout(5_000),
      });
      return reply.code(r.ok ? 200 : 404).send();
    },
  );

  // --- recording ---
  app.post('/api/record/start', async () => recorder.start());
  app.post('/api/record/stop', async () => recorder.stop());

  app.get<{ Querystring: ListQuery }>('/api/recordings', { schema: { querystring: listQuery } }, async (req) =>
    db.listRecordings(req.query.limit, req.query.before).map(recordingDto),
  );

  const getRecording = (id: string) => {
    const row = db.getRecording(id);
    if (!row) throw new HttpError(404, 'recording not found');
    return row;
  };

  app.get<{ Params: IdParams }>('/api/recordings/:id', { schema: { params: idParams } }, async (req) =>
    recordingDto(getRecording(req.params.id)),
  );

  app.get<{ Params: IdParams }>('/api/recordings/:id/file', { schema: { params: idParams } }, (req, reply) =>
    reply.sendFile(getRecording(req.params.id).path),
  );

  app.get<{ Params: IdParams }>('/api/recordings/:id/thumb', { schema: { params: idParams } }, (req, reply) => {
    const row = getRecording(req.params.id);
    if (!row.thumb_path) throw new HttpError(404, 'no thumbnail');
    return reply.sendFile(row.thumb_path);
  });

  app.delete<{ Params: IdParams }>('/api/recordings/:id', { schema: { params: idParams } }, async (req) => {
    const row = getRecording(req.params.id);
    await removeFile(toAbs(cfg, row.path));
    if (row.thumb_path) await removeFile(toAbs(cfg, row.thumb_path));
    db.deleteRecording(row.id);
    return { deleted: row.id };
  });

  // --- snapshots ---
  app.post('/api/snapshot', async () => snapshots.take());

  app.get<{ Querystring: ListQuery }>('/api/snapshots', { schema: { querystring: listQuery } }, async (req) =>
    db.listSnapshots(req.query.limit, req.query.before).map(snapshotDto),
  );

  const getSnapshot = (id: string) => {
    const row = db.getSnapshot(id);
    if (!row) throw new HttpError(404, 'snapshot not found');
    return row;
  };

  app.get<{ Params: IdParams }>('/api/snapshots/:id', { schema: { params: idParams } }, async (req) =>
    snapshotDto(getSnapshot(req.params.id)),
  );

  app.get<{ Params: IdParams }>('/api/snapshots/:id/file', { schema: { params: idParams } }, (req, reply) =>
    reply.sendFile(getSnapshot(req.params.id).path),
  );

  app.get<{ Params: IdParams }>('/api/snapshots/:id/thumb', { schema: { params: idParams } }, (req, reply) => {
    const row = getSnapshot(req.params.id);
    if (!row.thumb_path) throw new HttpError(404, 'no thumbnail');
    return reply.sendFile(row.thumb_path);
  });

  app.delete<{ Params: IdParams }>('/api/snapshots/:id', { schema: { params: idParams } }, async (req) => {
    const row = getSnapshot(req.params.id);
    await removeFile(toAbs(cfg, row.path));
    if (row.thumb_path) await removeFile(toAbs(cfg, row.thumb_path));
    db.deleteSnapshot(row.id);
    return { deleted: row.id };
  });

  // --- event log ---
  app.get<{ Querystring: ListQuery }>('/api/events', { schema: { querystring: listQuery } }, async (req) =>
    db.listEvents(req.query.limit, req.query.before).map((e) => ({
      id: e.id,
      type: e.type,
      ts: e.ts,
      data: e.data ? (JSON.parse(e.data) as unknown) : null,
    })),
  );

  // --- live events over WebSocket: first message is {type:"hello", status}, then every bus event ---
  app.get('/api/ws', { websocket: true }, (socket) => {
    const off = bus.on((ev) => {
      if (socket.readyState === socket.OPEN) socket.send(JSON.stringify(ev));
    });
    socket.on('close', off);
    void status().then((s) => socket.send(JSON.stringify({ type: 'hello', ts: Date.now(), status: s })));
  });

  return app;
}
