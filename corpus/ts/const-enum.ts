// const enum : compilé comme un enum normal (raccourci phase 3).
const enum Level {
  Debug,
  Info,
  Warn,
  Error,
}

function log(level: Level, msg: string): void {
  if (level >= Level.Warn) console.error(msg);
  else console.log(msg);
}

export { log };
