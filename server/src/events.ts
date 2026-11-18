import { EventEmitter } from 'node:events';
import type { PresetName } from './config.js';
import type { RecordingDto, SnapshotDto } from './dto.js';

/**
 * Everything that happens in the system goes through this bus. The WebSocket
 * forwards all events to the app; selected ones are persisted to the events table.
 * Motion detection will publish `motion.*` events here later.
 */
export type NvrEvent =
  | { type: 'camera.online' }
  | { type: 'camera.offline'; reason?: string }
  | { type: 'camera.starting' }
  | { type: 'camera.idle' }
  | { type: 'preset.changed'; preset: PresetName }
  | { type: 'recording.started'; sessionId: string; startedAt: number }
  | { type: 'recording.stopped'; sessionId: string }
  | { type: 'recording.saved'; recording: RecordingDto }
  | { type: 'recording.error'; message: string }
  | { type: 'snapshot.saved'; snapshot: SnapshotDto };

export type NvrEventEnvelope = NvrEvent & { ts: number };

/** Event types written to the database event log. */
export const PERSISTED_EVENTS = new Set<NvrEvent['type']>([
  'camera.online',
  'camera.offline',
  'recording.started',
  'recording.stopped',
  'recording.error',
]);

export class EventBus {
  private readonly ee = new EventEmitter();

  constructor() {
    this.ee.setMaxListeners(100);
  }

  emit(event: NvrEvent): void {
    const env: NvrEventEnvelope = { ...event, ts: Date.now() };
    this.ee.emit('event', env);
  }

  /** Subscribe; returns an unsubscribe function. */
  on(fn: (e: NvrEventEnvelope) => void): () => void {
    this.ee.on('event', fn);
    return () => this.ee.off('event', fn);
  }
}
