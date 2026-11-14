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
`;

const BEFORE_MAX = Number.MAX_SAFE_INTEGER;

export class Db {
  private readonly db: Database.Database;

  constructor(file: string) {
    this.db = new Database(file);
    this.db.pragma('journal_mode = WAL');
    this.db.exec(SCHEMA);
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

  listRecordings(limit: number, before?: number): RecordingRow[] {
    return this.db
      .prepare(`SELECT * FROM recordings WHERE started_at < ? ORDER BY started_at DESC LIMIT ?`)
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
