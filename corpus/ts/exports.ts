// export type / export interface (déclarations type-only exportées, effacées).
export type ID = string;
export type Result<T> = { ok: true; value: T } | { ok: false; error: string };

export interface Logger {
  log(msg: string): void;
  level: number;
}

export function ok<T>(value: T): Result<T> {
  return { ok: true, value };
}

export const version: string = "1.0.0";
