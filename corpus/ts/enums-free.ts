// Constantes typées + type literal comme "enum" (les vrais `enum` sont HORS phase 1).
type Level = "debug" | "info" | "warn" | "error";

const LEVELS: readonly Level[] = ["debug", "info", "warn", "error"];

function severity(level: Level): number {
  const order: Record<Level, number> = {
    debug: 0,
    info: 1,
    warn: 2,
    error: 3,
  };
  return order[level];
}

export { LEVELS, severity };
