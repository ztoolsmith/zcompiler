// import type / export type / spécificateurs type mixtes (phase 2).
import type { Readable } from "node:stream";
import { readFile, type PathLike } from "node:fs";
import { type EventEmitter, EventEmitter as EE } from "node:events";

type Options = { path: PathLike; stream?: Readable };

function open(opts: Options): void {
  const emitter: EventEmitter = new EE();
  readFile(opts.path, () => emitter.emit("done"));
}

export { open };
export type { Options };
