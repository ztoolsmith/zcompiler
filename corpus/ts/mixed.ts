// Mélange réaliste : imports, closures typées, génériques, as, optionnels.
import { readFile } from "node:fs/promises";

interface Options {
  encoding?: string;
  cache?: boolean;
}

type Middleware<Req, Res> = (req: Req, res: Res, next: () => void) => void;

const store = new Map();

function memoize<A, R>(fn: (arg: A) => R): (arg: A) => R {
  return (arg: A): R => {
    if (store.has(arg)) return store.get(arg) as R;
    const value: R = fn(arg);
    store.set(arg, value);
    return value;
  };
}

async function loadConfig(path: string, opts: Options = {}): Promise<object> {
  const text = await readFile(path, opts.encoding as BufferEncoding);
  return JSON.parse(text as string);
}

export { memoize, loadConfig };

