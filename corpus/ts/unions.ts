// Unions, intersections, littéraux, alias de types.
type Id = string | number;
type Nullable<T> = T | null | undefined;
type Direction = "north" | "south" | "east" | "west";
type Handler = (event: string, data: unknown) => void;
type Mix = { a: number } & { b: string };

let key: Id = 42;
let dir: Direction = "north";
const noop: Handler = (e, d) => {};

function pick(value: Nullable<string>): string {
  return value != null ? value : "default";
}

export { pick, noop, key, dir };
