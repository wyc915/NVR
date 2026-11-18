import Database from 'better-sqlite3';

export interface RecordingRow {
  id: string;
  session_id: string | null;
  /** Path relative to storageDir, forward slashes. */
  path: string;
  thumb_path: string | null;
  started_at: number;
  ended_at: number | null;
  duration: number | null;
  size: number | null;
  preset: string | null;
  /** 1 = kept on purpose (shown with a star, can be filtered). */
  starred?: number;
}

export interface SnapshotRow {
  id: string;
  path: string;
  thumb_path: string | null;
  taken_at: number;
  size: number | null;
  preset: string | null;
}

export interface EventRow {
  id: number;
  type: string;
  ts: number;
  data: string | null;
}

const SCHEMA = `
CREATE TABLE IF NOT EXISTS recordings (
  id          TEXT PRIMARY KEY,
  session_id  TEXT,
  path        TEXT NOT NULL,
  thumb_path  TEXT,
  started_at  INTEGER NOT NULL,
  ended_at    INTEGER,
  duration    REAL,
  size        INTEGER,
  preset      TEXT
);
CREATE INDEX IF NOT EXISTS idx_recordings_started ON recordings(started_at DESC);

CREATE TABLE IF NOT EXISTS snapshots (
  id          TEXT PRIMARY KEY,
  path        TEXT NOT NULL,
  thumb_path  TEXT,
  taken_at    INTEGER NOT NULL,
  size        INTEGER,
  preset      TEXT
);
CREATE INDEX IF NOT EXISTS idx_snapshots_taken ON snapshots(taken_at DESC);

-- Event log (camera online/offline, recording start/stop; later: motion).
CREATE TABLE IF NOT EXISTS events (
  id    INTEGER PRIMARY KEY AUTOINCREMENT,
  type  TEXT NOT NULL,
  ts    INTEGER NOT NULL,
  data  TEXT
);
CREATE INDEX IF NOT EXISTS idx_events_ts ON events(ts DESC);

CREATE TABLE IF NOT EXISTS settings (
  key    TEXT PRIMARY KEY,
  value  TEXT NOT NULL
);

-- Passkey login: a device (phone/browser) has one or more WebAuthn credentials
-- and gets short-lived sessions. Revoking a device deletes all of them.
CREATE TABLE IF NOT EXISTS devices (
  id            TEXT PRIMARY KEY,
  name          TEXT NOT NULL,
  created_at    INTEGER NOT NULL,
  last_seen_at  INTEGER,
  last_ip       TEXT
);

CREATE TABLE IF NOT EXISTS credentials (
  id          TEXT PRIMARY KEY,           -- base64url credential ID
  device_id   TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  public_key  BLOB NOT NULL,
  counter     INTEGER NOT NULL,
  transports  TEXT,
  created_at  INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS sessions (
  id           TEXT PRIMARY KEY,
  device_id    TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  secret_hash  TEXT NOT NULL,             -- sha256 of the secret part, never the secret
  url_key      TEXT NOT NULL,             -- HMAC key for this session's signed media URLs
  created_at   INTEGER NOT NULL,
  expires_at   INTEGER NOT NULL,
  ip           TEXT
);
CREATE INDEX IF NOT EXISTS idx_sessions_device ON sessions(device_id);
`;

export interface DeviceRow {
  id: string;
  name: string;
  created_at: number;
  last_seen_at: number | null;
  last_ip: string | null;
}

export interface CredentialRow {
  id: string;
  device_id: string;
  public_key: Buffer;
  counter: number;
  transports: string | null;
  created_at: number;
}

export interface SessionRow {
  id: string;
  device_id: string;
  secret_hash: string;
  url_key: string;
  created_at: number;
  expires_at: number;
  ip: string | null;
}

const BEFORE_MAX = Number.MAX_SAFE_INTEGER;

export class Db {
  private readonly db: Database.Database;

  constructor(file: string) {
    this.db = new Database(file);
    this.db.pragma('journal_mode = WAL');
    this.db.pragma('foreign_keys = ON');
    this.db.exec(SCHEMA);
    this.migrate();
  }

  /** Columns added after the first release. */
  private migrate(): void {
    const cols = (this.db.prepare(`PRAGMA table_info(recordings)`).all() as { name: string }[]).map((c) => c.name);
    if (!cols.includes('starred')) {
      this.db.exec(`ALTER TABLE recordings ADD COLUMN starred INTEGER NOT NULL DEFAULT 0`);
    }
  }

  setRecordingStarred(id: string, starred: boolean): void {
    this.db.prepare(`UPDATE recordings SET starred = ? WHERE id = ?`).run(starred ? 1 : 0, id);
  }

  /** Count and total size per media table. */
  mediaStats(): { recordings: { count: number; bytes: number }; snapshots: { count: number; bytes: number } } {
    const q = (t: string) =>
      this.db.prepare(`SELECT COUNT(*) AS count, COALESCE(SUM(size), 0) AS bytes FROM ${t}`).get() as {
        count: number;
        bytes: number;
      };
    return { recordings: q('recordings'), snapshots: q('snapshots') };
  }

  // --- devices / passkeys / sessions ---
  insertDevice(d: DeviceRow, c: CredentialRow): void {
    this.db.transaction(() => {
      this.db
        .prepare(`INSERT INTO devices (id, name, created_at, last_seen_at, last_ip) VALUES (@id, @name, @created_at, @last_seen_at, @last_ip)`)
        .run(d);
      this.db
        .prepare(
          `INSERT INTO credentials (id, device_id, public_key, counter, transports, created_at)
           VALUES (@id, @device_id, @public_key, @counter, @transports, @created_at)`,
        )
        .run(c);
    })();
  }

  listDevices(): DeviceRow[] {
    return this.db.prepare(`SELECT * FROM devices ORDER BY COALESCE(last_seen_at, created_at) DESC`).all() as DeviceRow[];
  }

  getDevice(id: string): DeviceRow | undefined {
    return this.db.prepare(`SELECT * FROM devices WHERE id = ?`).get(id) as DeviceRow | undefined;
  }

  touchDevice(id: string, ts: number, ip: string): void {
    this.db.prepare(`UPDATE devices SET last_seen_at = ?, last_ip = ? WHERE id = ?`).run(ts, ip, id);
  }

  /** Deletes the device with its credentials and sessions; returns the deleted session IDs. */
  deleteDevice(id: string): string[] {
    return this.db.transaction(() => {
      const sids = (this.db.prepare(`SELECT id FROM sessions WHERE device_id = ?`).all(id) as { id: string }[]).map(
        (r) => r.id,
      );
      this.db.prepare(`DELETE FROM devices WHERE id = ?`).run(id);
      return sids;
    })();
  }

  getCredential(id: string): CredentialRow | undefined {
    return this.db.prepare(`SELECT * FROM credentials WHERE id = ?`).get(id) as CredentialRow | undefined;
  }

  listCredentialIds(): { id: string; transports: string | null }[] {
    return this.db.prepare(`SELECT id, transports FROM credentials`).all() as { id: string; transports: string | null }[];
  }

  updateCredentialCounter(id: string, counter: number): void {
    this.db.prepare(`UPDATE credentials SET counter = ? WHERE id = ?`).run(counter, id);
  }

  insertSession(s: SessionRow): void {
    this.db
      .prepare(
        `INSERT INTO sessions (id, device_id, secret_hash, url_key, created_at, expires_at, ip)
         VALUES (@id, @device_id, @secret_hash, @url_key, @created_at, @expires_at, @ip)`,
      )
      .run(s);
  }

  getSession(id: string): SessionRow | undefined {
    return this.db.prepare(`SELECT * FROM sessions WHERE id = ?`).get(id) as SessionRow | undefined;
  }

  deleteSession(id: string): void {
    this.db.prepare(`DELETE FROM sessions WHERE id = ?`).run(id);
  }

  deleteExpiredSessions(now: number): void {
    this.db.prepare(`DELETE FROM sessions WHERE expires_at <= ?`).run(now);
  }

  close(): void {
    this.db.close();
  }

  // --- recordings ---
  insertRecording(r: RecordingRow): RecordingRow {
    this.db
      .prepare(
        `INSERT INTO recordings (id, session_id, path, thumb_path, started_at, ended_at, duration, size, preset)
         VALUES (@id, @session_id, @path, @thumb_path, @started_at, @ended_at, @duration, @size, @preset)`,
      )
      .run(r);
    return r;
  }

  listRecordings(limit: number, before?: number, starredOnly = false): RecordingRow[] {
    return this.db
      .prepare(
        `SELECT * FROM recordings WHERE started_at < ? ${starredOnly ? 'AND starred = 1' : ''}
         ORDER BY started_at DESC LIMIT ?`,
      )
      .all(before ?? BEFORE_MAX, limit) as RecordingRow[];
  }

  getRecording(id: string): RecordingRow | undefined {
    return this.db.prepare(`SELECT * FROM recordings WHERE id = ?`).get(id) as RecordingRow | undefined;
  }

  deleteRecording(id: string): void {
    this.db.prepare(`DELETE FROM recordings WHERE id = ?`).run(id);
  }

  // --- snapshots ---
  insertSnapshot(s: SnapshotRow): SnapshotRow {
    this.db
      .prepare(
        `INSERT INTO snapshots (id, path, thumb_path, taken_at, size, preset)
         VALUES (@id, @path, @thumb_path, @taken_at, @size, @preset)`,
      )
      .run(s);
    return s;
  }

  listSnapshots(limit: number, before?: number): SnapshotRow[] {
    return this.db
      .prepare(`SELECT * FROM snapshots WHERE taken_at < ? ORDER BY taken_at DESC LIMIT ?`)
      .all(before ?? BEFORE_MAX, limit) as SnapshotRow[];
  }

  getSnapshot(id: string): SnapshotRow | undefined {
    return this.db.prepare(`SELECT * FROM snapshots WHERE id = ?`).get(id) as SnapshotRow | undefined;
  }

  deleteSnapshot(id: string): void {
    this.db.prepare(`DELETE FROM snapshots WHERE id = ?`).run(id);
  }

  // --- events ---
  insertEvent(type: string, ts: number, data: unknown): void {
    this.db.prepare(`INSERT INTO events (type, ts, data) VALUES (?, ?, ?)`).run(type, ts, JSON.stringify(data));
  }

  listEventsExceptTypes(types: string[], limit: number): EventRow[] {
    return this.db
      .prepare(`SELECT * FROM events WHERE type NOT IN (${types.map(() => '?').join(',')}) ORDER BY ts DESC LIMIT ?`)
      .all(...types, limit) as EventRow[];
  }

  listEventsOfTypes(types: string[], limit: number): EventRow[] {
    return this.db
      .prepare(`SELECT * FROM events WHERE type IN (${types.map(() => '?').join(',')}) ORDER BY ts DESC LIMIT ?`)
      .all(...types, limit) as EventRow[];
  }

  listEvents(limit: number, before?: number): EventRow[] {
    return this.db
      .prepare(`SELECT * FROM events WHERE ts < ? ORDER BY ts DESC LIMIT ?`)
      .all(before ?? BEFORE_MAX, limit) as EventRow[];
  }

  // --- settings ---
  getSetting(key: string): string | undefined {
    const row = this.db.prepare(`SELECT value FROM settings WHERE key = ?`).get(key) as
      | { value: string }
      | undefined;
    return row?.value;
  }

  setSetting(key: string, value: string): void {
    this.db
      .prepare(`INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value`)
      .run(key, value);
  }
}
