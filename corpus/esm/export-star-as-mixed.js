// Un barrel réaliste : namespaces, re-exports, imports locaux, tout mélangé.
import { format } from './format.js';
import * as internals from './internals.js';

export * as parser from './parser/index.js';
export * as printer from './printer/index.js';
export * from './types.js';
export { format };

export const version = internals.VERSION;
export function run(src) {
  return format(src);
}
