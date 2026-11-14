import { pino, type Logger } from 'pino';

export type { Logger };

export function createLogger(level = 'info'): Logger {
  return pino({
    level,
    transport: {
      target: 'pino-pretty',
      options: {
        translateTime: 'SYS:yyyy-mm-dd HH:MM:ss',
        ignore: 'pid,hostname',
        // No ANSI color codes when running as a service (output goes to a log file).
        colorize: Boolean(process.stdout.isTTY),
      },
    },
  });
}
