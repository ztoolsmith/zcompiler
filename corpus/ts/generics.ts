// Fonctions génériques (déclaration <T>), contraintes, défauts, types imbriqués.
function identity<T>(x: T): T {
  return x;
}

function firstOf<T>(list: T[]): T | undefined {
  return list.length > 0 ? list[0] : undefined;
}

function merge<A, B = {}>(a: A, b: B): A & B {
  return Object.assign({}, a, b);
}

type Dict<V> = Record<string, V>;
type Matrix = Array<Array<number>>;

const nums: Array<number> = [1, 2, 3];
const flat = identity(nums);
export { identity, firstOf, merge, flat };
