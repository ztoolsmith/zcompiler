// Appels génériques (phase 2) : foo<T>(x), new C<T>(), chaînes Map<K, V[]>.
function identity<T>(x: T): T {
  return x;
}

const n = identity<number>(42);
const s = identity<string>("hi");

const cache = new Map<string, number[]>();
cache.set("a", [1, 2, 3]);

const set = new Set<string>();
const pair = new Map<string, Map<number, boolean>>();

function wrap<A, B>(a: A, b: B): [A, B] {
  return [a, b];
}
const w = wrap<number, string>(1, "x");

// Comparaisons voisines : NE doivent PAS devenir des génériques.
const cmp = n < s.length && cache.size > 0;
export { identity, n, cache, set, pair, w, cmp };
