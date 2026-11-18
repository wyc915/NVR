import type { RecordingRow, SnapshotRow } from './db.js';

/** JSON shapes returned by the API (camelCase, with URLs the app can fetch). */

export interface RecordingDto {
  id: string;
  sessionId: string | null;
  startedAt: number;
  endedAt: number | null;
  duration: number | null;
  size: number | null;
  preset: string | null;
  fileUrl: string;
  thumbUrl: string | null;
  starred: boolean;
}

export interface SnapshotDto {
  id: string;
  takenAt: number;
  size: number | null;
  preset: string | null;
  fileUrl: string;
  thumbUrl: string | null;
}

export const recordingDto = (r: RecordingRow): RecordingDto => ({
  id: r.id,
  sessionId: r.session_id,
  startedAt: r.started_at,
  endedAt: r.ended_at,
  duration: r.duration,
  size: r.size,
  preset: r.preset,
  fileUrl: `/api/recordings/${r.id}/file`,
  thumbUrl: r.thumb_path ? `/api/recordings/${r.id}/thumb` : null,
  starred: r.starred === 1,
});

export const snapshotDto = (s: SnapshotRow): SnapshotDto => ({
  id: s.id,
  takenAt: s.taken_at,
  size: s.size,
  preset: s.preset,
  fileUrl: `/api/snapshots/${s.id}/file`,
  thumbUrl: s.thumb_path ? `/api/snapshots/${s.id}/thumb` : null,
});
