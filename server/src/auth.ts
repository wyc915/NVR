import {
  generateAuthenticationOptions,
  generateRegistrationOptions,
  verifyAuthenticationResponse,
  verifyRegistrationResponse,
  type AuthenticationResponseJSON,
  type AuthenticatorTransportFuture,
  type RegistrationResponseJSON,
} from '@simplewebauthn/server';
import crypto from 'node:crypto';
import type { Config } from './config.js';
import type { Db, DeviceRow } from './db.js';
import type { EventBus } from './events.js';
import type { Logger } from './log.js';
import { isLoopback, safeEqual, UrlSigner } from './security.js';
import { HttpError } from './util/errors.js';

/** Who made a request: the API token (PC, Android app) or a passkey session (iPhone web app). */
export type AuthContext = { kind: 'token' } | { kind: 'session'; sessionId: string; deviceId: string };

export interface DeviceDto {
  id: string;
  name: string;
  createdAt: number;
  lastSeenAt: number | null;
  lastIp: string | null;
  current: boolean;
}

interface Flow {
  type: 'register' | 'login';
  challenge: string;
  origin: string;
  rpID: string;
  expires: number;
  deviceName?: string;
}

const FLOW_TTL_MS = 5 * 60_000;
const PAIR_TTL_MS = 5 * 60_000;
const PAIR_MAX_TRIES = 5;
const TOUCH_EVERY_MS = 60_000;
const RP_NAME = '監控';
/** Log API-token use from an address again after this long (the PC itself is never logged). */
const TOKEN_LOG_EVERY_MS = 12 * 3600_000;

/**
 * Passkey (WebAuthn / Face ID) login with per-device sessions.
 *
 * - A new device proves it may register with the API token, an existing session, or a
 *   6-digit pairing code shown on an already signed-in device. It then creates a passkey.
 * - Logging in with the passkey issues a session token `s1.<id>.<secret>` valid for
 *   `auth.sessionHours`. Only a hash of the secret is stored. The app derives its signed-URL
 *   key from the full token, the server stores that derived key per session.
 * - Revoking a device deletes its passkey and sessions at once.
 */
export class Auth {
  private readonly flows = new Map<string, Flow>();
  private readonly pairCodes = new Map<string, { expires: number; tries: number }>();
  private readonly lastTouch = new Map<string, number>();
  private readonly tokenSeen = new Map<string, number>();

  constructor(
    private readonly cfg: Config,
    private readonly db: Db,
    private readonly bus: EventBus,
    private readonly log: Logger,
  ) {
    setInterval(() => this.prune(), 60_000).unref();
  }

  // ---------------------------------------------------------------- requests

  /** Check a Bearer token. */
  authenticate(bearer: string, ip: string): AuthContext | null {
    if (safeEqual(bearer, this.cfg.token)) {
      this.noteTokenUse(ip);
      return { kind: 'token' };
    }
    const s = this.sessionFor(bearer);
    if (!s) return null;
    this.touch(s.device_id, ip);
    return { kind: 'session', sessionId: s.id, deviceId: s.device_id };
  }

  /** The API token works everywhere, so record (and announce) where it's used from. */
  private noteTokenUse(ip: string): void {
    if (isLoopback(ip)) return;
    const now = Date.now();
    if (now - (this.tokenSeen.get(ip) ?? 0) < TOKEN_LOG_EVERY_MS) return;
    this.tokenSeen.set(ip, now);
    this.bus.emit({ type: 'auth.token', ip });
  }

  /** Signing key for media URLs carrying `sid` (null if the session is gone/expired). */
  urlKey(sessionId: string): Buffer | null {
    const s = this.db.getSession(sessionId);
    if (!s || s.expires_at <= Date.now()) return null;
    return Buffer.from(s.url_key, 'base64url');
  }

  private sessionFor(token: string) {
    const m = /^s1\.([0-9a-f-]{36})\.([A-Za-z0-9_-]{43})$/.exec(token);
    if (!m) return null;
    const s = this.db.getSession(m[1]);
    if (!s || s.expires_at <= Date.now()) return null;
    return safeEqual(sha256(m[2]), s.secret_hash) ? s : null;
  }

  private touch(deviceId: string, ip: string): void {
    const now = Date.now();
    if (now - (this.lastTouch.get(deviceId) ?? 0) < TOUCH_EVERY_MS) return;
    this.lastTouch.set(deviceId, now);
    this.db.touchDevice(deviceId, now, ip);
  }

  // ---------------------------------------------------------------- pairing codes

  createPairCode(): { code: string; expiresAt: number } {
    const code = String(crypto.randomInt(0, 1_000_000)).padStart(6, '0');
    const expires = Date.now() + PAIR_TTL_MS;
    this.pairCodes.set(code, { expires, tries: 0 });
    return { code, expiresAt: expires };
  }

  /** Single use. Returns false for unknown/expired codes. */
  private consumePairCode(code: string): boolean {
    const p = this.pairCodes.get(code);
    if (!p || p.expires <= Date.now()) return false;
    this.pairCodes.delete(code);
    return true;
  }

  /** A wrong code counts against every open code, so guessing can't run through them. */
  private failPairCode(): void {
    for (const [code, p] of this.pairCodes) if (++p.tries >= PAIR_MAX_TRIES) this.pairCodes.delete(code);
  }

  // ---------------------------------------------------------------- registration

  /**
   * Start registering a passkey for a new device. Allowed with the API token / a session
   * (`authorized`), or with a pairing code.
   */
  async registerOptions(origin: string | undefined, name: string, authorized: boolean, pairCode?: string) {
    const o = this.checkOrigin(origin);
    if (!authorized) {
      if (!pairCode || !this.consumePairCode(pairCode)) {
        this.failPairCode();
        throw new HttpError(401, 'invalid pairing code');
      }
    }
    const deviceName = name.trim().slice(0, 40) || '裝置';
    const options = await generateRegistrationOptions({
      rpName: RP_NAME,
      rpID: o.rpID,
      userName: deviceName,
      userDisplayName: `監控 · ${deviceName}`,
      attestationType: 'none',
      // One passkey per device; Face ID / Touch ID / device PIN is required every time.
      authenticatorSelection: { residentKey: 'required', userVerification: 'required' },
      excludeCredentials: [],
    });
    return { flowId: this.addFlow({ type: 'register', challenge: options.challenge, ...o, deviceName }), options };
  }

  async registerVerify(flowId: string, response: RegistrationResponseJSON, ip: string) {
    const f = this.takeFlow(flowId, 'register');
    const v = await verifyRegistrationResponse({
      response,
      expectedChallenge: f.challenge,
      expectedOrigin: f.origin,
      expectedRPID: f.rpID,
      requireUserVerification: true,
    }).catch((err: unknown) => {
      this.log.warn({ err: String(err) }, 'passkey registration rejected');
      return null;
    });
    if (!v?.verified) throw new HttpError(400, 'passkey registration failed');

    const now = Date.now();
    const device: DeviceRow = { id: crypto.randomUUID(), name: f.deviceName ?? '裝置', created_at: now, last_seen_at: now, last_ip: ip };
    const c = v.registrationInfo.credential;
    this.db.insertDevice(device, {
      id: c.id,
      device_id: device.id,
      public_key: Buffer.from(c.publicKey),
      counter: c.counter,
      transports: c.transports ? JSON.stringify(c.transports) : null,
      created_at: now,
    });
    this.log.info({ device: device.name, ip }, 'new device registered a passkey');
    this.bus.emit({ type: 'device.added', deviceId: device.id, name: device.name, ip });
    return this.issueSession(device, ip);
  }

  // ---------------------------------------------------------------- login

  async loginOptions(origin: string | undefined) {
    const o = this.checkOrigin(origin);
    // Discoverable credentials: the phone offers the passkey it has for this site.
    const options = await generateAuthenticationOptions({ rpID: o.rpID, userVerification: 'required' });
    return { flowId: this.addFlow({ type: 'login', challenge: options.challenge, ...o }), options };
  }

  async loginVerify(flowId: string, response: AuthenticationResponseJSON, ip: string) {
    const f = this.takeFlow(flowId, 'login');
    const cred = this.db.getCredential(response.id);
    if (!cred) throw new HttpError(401, 'unknown passkey');
    const v = await verifyAuthenticationResponse({
      response,
      expectedChallenge: f.challenge,
      expectedOrigin: f.origin,
      expectedRPID: f.rpID,
      requireUserVerification: true,
      credential: {
        id: cred.id,
        publicKey: new Uint8Array(cred.public_key),
        counter: cred.counter,
        transports: cred.transports ? (JSON.parse(cred.transports) as AuthenticatorTransportFuture[]) : undefined,
      },
    }).catch((err: unknown) => {
      this.log.warn({ err: String(err) }, 'passkey login rejected');
      return null;
    });
    if (!v?.verified) throw new HttpError(401, 'passkey login failed');
    this.db.updateCredentialCounter(cred.id, v.authenticationInfo.newCounter);

    const device = this.db.getDevice(cred.device_id)!;
    this.db.touchDevice(device.id, Date.now(), ip);
    this.bus.emit({ type: 'auth.login', deviceId: device.id, name: device.name, ip });
    return this.issueSession(device, ip);
  }

  logout(sessionId: string): void {
    this.db.deleteSession(sessionId);
  }

  // ---------------------------------------------------------------- devices

  listDevices(ctx: AuthContext): DeviceDto[] {
    return this.db.listDevices().map((d) => ({
      id: d.id,
      name: d.name,
      createdAt: d.created_at,
      lastSeenAt: d.last_seen_at,
      lastIp: d.last_ip,
      current: ctx.kind === 'session' && ctx.deviceId === d.id,
    }));
  }

  /** Returns the session IDs that were revoked (so open WebSockets can be closed). */
  revokeDevice(id: string): string[] {
    const d = this.db.getDevice(id);
    if (!d) throw new HttpError(404, 'device not found');
    const sids = this.db.deleteDevice(id);
    this.lastTouch.delete(id);
    this.log.warn({ device: d.name }, 'device revoked');
    this.bus.emit({ type: 'device.revoked', deviceId: id, name: d.name });
    return sids;
  }

  // ---------------------------------------------------------------- internals

  private issueSession(device: DeviceRow, ip: string) {
    const id = crypto.randomUUID();
    const secret = crypto.randomBytes(32).toString('base64url'); // 43 chars
    const token = `s1.${id}.${secret}`;
    const now = Date.now();
    const expiresAt = now + this.cfg.auth.sessionHours * 3600_000;
    this.db.insertSession({
      id,
      device_id: device.id,
      secret_hash: sha256(secret),
      url_key: UrlSigner.deriveKey(token).toString('base64url'),
      created_at: now,
      expires_at: expiresAt,
      ip,
    });
    return { token, expiresAt, device: { id: device.id, name: device.name } };
  }

  /** Passkeys are bound to the site's hostname, so only accept our own web origins. */
  private checkOrigin(origin: string | undefined): { origin: string; rpID: string } {
    let u: URL;
    try {
      u = new URL(origin ?? '');
    } catch {
      throw new HttpError(400, 'passkeys need the web app (missing Origin)');
    }
    const allowed = this.cfg.auth.origins.length
      ? this.cfg.auth.origins.includes(u.origin)
      : (u.protocol === 'https:' && u.hostname.endsWith('.ts.net')) ||
        (u.protocol === 'http:' && u.hostname === 'localhost' && u.port === String(this.cfg.port));
    if (!allowed) throw new HttpError(400, `passkeys are not available on ${u.origin}`);
    return { origin: u.origin, rpID: u.hostname };
  }

  private addFlow(f: Omit<Flow, 'expires'>): string {
    const id = crypto.randomUUID();
    this.flows.set(id, { ...f, expires: Date.now() + FLOW_TTL_MS });
    return id;
  }

  private takeFlow(id: string, type: Flow['type']): Flow {
    const f = this.flows.get(id);
    this.flows.delete(id);
    if (!f || f.type !== type || f.expires <= Date.now()) throw new HttpError(400, 'expired, please try again');
    return f;
  }

  private prune(): void {
    const now = Date.now();
    for (const [k, f] of this.flows) if (f.expires <= now) this.flows.delete(k);
    for (const [k, p] of this.pairCodes) if (p.expires <= now) this.pairCodes.delete(k);
    this.db.deleteExpiredSessions(now);
  }
}

const sha256 = (s: string) => crypto.createHash('sha256').update(s).digest('hex');
