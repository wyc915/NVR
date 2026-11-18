import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

/** server/ directory (works from both src/ via tsx and dist/ after build). */
export const SERVER_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

export type PresetName = '1080p' | '720p';

export interface Preset {
  size: string;
  fps: number;
  bitrate: string;
  maxrate: string;
  bufsize: string;
}

export const PRESETS: Record<PresetName, Preset> = {
  '1080p': { size: '1920x1080', fps: 30, bitrate: '4M', maxrate: '5M', bufsize: '8M' },
  '720p': { size: '1280x720', fps: 15, bitrate: '1200k', maxrate: '1500k', bufsize: '2400k' },
};

export const isPresetName = (v: unknown): v is PresetName =>
  typeof v === 'string' && Object.hasOwn(PRESETS, v);

export interface Config {
  host: string;
  port: number;
  token: string;
  /** CIDRs allowed to reach the API and watch the stream (loopback is always allowed). */
  allowedNetworks: string[];
  logLevel: string;
  ffmpegPath: string;
  ffprobePath: string;
  mediamtxPath: string;
  mediamtxConfig: string;
  mediamtxApi: string;
  rtspUrl: string;
  webrtcPort: number;
  streamPath: string;
  storageDir: string;
  /** Flutter web build served at "/" (for iPhone Safari via `tailscale serve`); skipped if missing. */
  webDir: string;
  camera: {
    video: string;
    audio: string | null;
    inputCodec: string | null;
    inputFps: number;
    encoder: 'nvenc' | 'x264';
    defaultPreset: PresetName;
    /** Only run the camera while someone watches, records or takes a snapshot. */
    onDemand: boolean;
    /** On-demand: stop the camera this long after the last viewer/recording ends. */
    idleSeconds: number;
  };
  recording: {
    maxSegmentMinutes: number;
    audioBitrate: string;
  };
}

function readJson(file: string): unknown {
  return JSON.parse(fs.readFileSync(file, 'utf8').replace(/^﻿/, ''));
}

/**
 * Loads server/config.json. On first run it is created from config.example.json
 * with a freshly generated API token.
 */
export function loadConfig(): Config {
  const file = path.join(SERVER_ROOT, 'config.json');
  const example = readJson(path.join(SERVER_ROOT, 'config.example.json')) as Config;
  if (!fs.existsSync(file)) {
    const fresh = { ...example, token: crypto.randomBytes(24).toString('base64url') };
    fs.writeFileSync(file, JSON.stringify(fresh, null, 2) + '\n', 'utf8');
    console.log(`Created ${file} with a new API token`);
  }
  const user = readJson(file) as Partial<Config>;
  // Settings missing from an older config.json fall back to config.example.json.
  const raw: Config = {
    ...example,
    ...user,
    camera: { ...example.camera, ...user.camera },
    recording: { ...example.recording, ...user.recording },
  };
  if (!raw.token || raw.token.length < 24) {
    throw new Error(`"token" in ${file} must be at least 24 characters (delete it to generate one)`);
  }
  if (!isPresetName(raw.camera.defaultPreset)) {
    throw new Error(`camera.defaultPreset must be one of ${Object.keys(PRESETS).join(', ')}`);
  }
  const abs = (p: string) => path.resolve(SERVER_ROOT, p);
  return {
    ...raw,
    // The Windows service runs as LocalSystem, whose PATH doesn't include the user's
    // winget links; the service installer passes absolute paths via these variables.
    ffmpegPath: process.env.NVR_FFMPEG || raw.ffmpegPath,
    ffprobePath: process.env.NVR_FFPROBE || raw.ffprobePath,
    mediamtxPath: abs(raw.mediamtxPath),
    mediamtxConfig: abs(raw.mediamtxConfig),
    storageDir: abs(raw.storageDir),
    webDir: abs(raw.webDir),
  };
}
