import crypto from 'node:crypto';
import net from 'node:net';

// ---------------------------------------------------------------------------
// Network allowlist
// ---------------------------------------------------------------------------

type IpType = 'ipv4' | 'ipv6';

/** Unwrap IPv4-mapped IPv6 addresses (::ffff:1.2.3.4) so IPv4 rules apply. */
export function normalizeIp(ip: string): { addr: string; type: IpType } {
  const m = /^::ffff:(\d+\.\d+\.\d+\.\d+)$/i.exec(ip);
  if (m) return { addr: m[1], type: 'ipv4' };
  return { addr: ip, type: net.isIPv6(ip) ? 'ipv6' : 'ipv4' };
}

export function isLoopback(ip: string): boolean {
  const { addr } = normalizeIp(ip);
  return addr === '::1' || addr.startsWith('127.');
}

export class NetworkAllowlist {
  private readonly list = new net.BlockList();

  /** @param cidrs e.g. ["127.0.0.1/32", "100.64.0.0/10", "fd7a:115c:a1e0::/48"] */
  constructor(cidrs: string[]) {
    for (const c of cidrs) {
      const [addr, prefix] = c.split('/');
      const type: IpType = net.isIPv6(addr) ? 'ipv6' : 'ipv4';
      if (!net.isIP(addr)) throw new Error(`allowedNetworks: invalid address "${c}"`);
      this.list.addSubnet(addr, prefix ? Number(prefix) : type === 'ipv6' ? 128 : 32, type);
    }
  }

  allows(ip: string): boolean {
    if (!ip) return false;
    const { addr, type } = normalizeIp(ip);
    return isLoopback(ip) || this.list.check(addr, type);
  }
}

// ---------------------------------------------------------------------------
// Secrets
// ---------------------------------------------------------------------------

export function safeEqual(given: string, expected: string): boolean {
  const a = Buffer.from(given);
  const b = Buffer.from(expected);
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

/**
 * Signed media URLs, so the API token never appears in a URL (where it would end up
 * in caches, history and logs). Image/video widgets and WebSockets can't always send
 * an Authorization header, so they use:
 *
 *   GET /api/recordings/<id>/file?exp=<unix s>&sig=<base64url HMAC-SHA256>
 *   sig = HMAC(key, "<path>\n<exp>"),  key = HMAC(token, "nvr-media-url-v1")
 *
 * A signature is bound to one path, is GET-only, and expires (max 24h ahead).
 */
const SIGNABLE_PATHS = /^\/api\/(?:(?:recordings|snapshots)\/[0-9a-f-]{36}\/(?:file|thumb)|ws)$/;
const MAX_TTL_S = 24 * 3600;
const CLOCK_SKEW_S = 300;

export class UrlSigner {
  private readonly key: Buffer;

  constructor(token: string) {
    this.key = crypto.createHmac('sha256', token).update('nvr-media-url-v1').digest();
  }

  sign(path: string, exp: number): string {
    return crypto.createHmac('sha256', this.key).update(`${path}\n${exp}`).digest('base64url');
  }

  verify(path: string, exp: unknown, sig: unknown, nowS = Math.floor(Date.now() / 1000)): boolean {
    if (!SIGNABLE_PATHS.test(path) || typeof sig !== 'string' || typeof exp !== 'string') return false;
    const e = Number(exp);
    if (!Number.isInteger(e)) return false;
    if (e < nowS - CLOCK_SKEW_S || e > nowS + MAX_TTL_S + CLOCK_SKEW_S) return false;
    return safeEqual(sig, this.sign(path, e));
  }
}

// ---------------------------------------------------------------------------
// Brute-force protection
// ---------------------------------------------------------------------------

/** Blocks an IP for `blockMs` after `max` failed auth attempts within `windowMs`. */
export class FailureLimiter {
  private readonly entries = new Map<string, { count: number; since: number; blockedUntil: number }>();

  constructor(
    private readonly max = 10,
    private readonly windowMs = 10 * 60_000,
    private readonly blockMs = 15 * 60_000,
  ) {}

  isBlocked(ip: string, now = Date.now()): boolean {
    const e = this.entries.get(ip);
    return !!e && e.blockedUntil > now;
  }

  /** Record a failure; returns true if the IP just got blocked. */
  fail(ip: string, now = Date.now()): boolean {
    let e = this.entries.get(ip);
    if (!e || now - e.since > this.windowMs) {
      e = { count: 0, since: now, blockedUntil: 0 };
      this.entries.set(ip, e);
    }
    e.count++;
    if (e.count >= this.max && e.blockedUntil <= now) {
      e.blockedUntil = now + this.blockMs;
      return true;
    }
    if (this.entries.size > 10_000) this.prune(now);
    return false;
  }

  private prune(now: number): void {
    for (const [ip, e] of this.entries) {
      if (e.blockedUntil <= now && now - e.since > this.windowMs) this.entries.delete(ip);
    }
  }
}
