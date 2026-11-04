/** JSON lines on stdout, one object per event: `{ts, level, msg, ...fields}`. Never given the keeper's key. */

export type Level = "debug" | "info" | "warn" | "error";
export type Fields = Record<string, unknown>;

export interface Logger {
  debug(msg: string, fields?: Fields): void;
  info(msg: string, fields?: Fields): void;
  warn(msg: string, fields?: Fields): void;
  error(msg: string, fields?: Fields): void;
}

const LEVELS: Record<Level, number> = { debug: 10, info: 20, warn: 30, error: 40 };
const SECRET = /(?:^|_|[a-z])(?:key|secret|password|mnemonic)$/i;

export function serialise(value: unknown): string {
  return JSON.stringify(value, (k, v: unknown) => {
    if (SECRET.test(k)) return "[redacted]";
    if (typeof v === "bigint") return v.toString();
    if (v instanceof Error) return { name: v.name, message: v.message };
    return v;
  });
}

export function createLogger(level: Level = "info", write: (line: string) => void = (l) => process.stdout.write(l)): Logger {
  const at = (l: Level) => (msg: string, fields: Fields = {}) => {
    if (LEVELS[l] < LEVELS[level]) return;
    write(`${serialise({ ts: new Date().toISOString(), level: l, msg, ...fields })}\n`);
  };
  return { debug: at("debug"), info: at("info"), warn: at("warn"), error: at("error") };
}
