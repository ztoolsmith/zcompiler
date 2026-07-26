// Enums numériques : auto-incrément, valeurs explicites, calculs constants.
enum Direction {
  North,
  East,
  South,
  West,
}

enum HttpStatus {
  OK = 200,
  NotFound = 404,
  ServerError = 500,
}

enum Flags {
  None = 0,
  Read = 1 << 0,
  Write = 1 << 1,
  Execute = 1 << 2,
  All = Read | Write | Execute,
}

function describe(d: Direction): string {
  return Direction[d];
}

const perm: Flags = Flags.Read | Flags.Write;
export { Direction, HttpStatus, Flags, describe, perm };
