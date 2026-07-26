// Types fonction, rest params typés, défauts, destructuring typé.
type Reducer<S> = (state: S, action: string) => S;

function reduce<S>(init: S, reducer: Reducer<S>, actions: string[]): S {
  let state: S = init;
  for (const a of actions) state = reducer(state, a);
  return state;
}

function sum(...nums: number[]): number {
  return nums.reduce((a, b) => a + b, 0);
}

function greet({ name, age = 0 }: { name: string; age?: number }): string {
  return name + " (" + age + ")";
}

const withDefault = (x: number = 10): number => x * 2;
export { reduce, sum, greet, withDefault };
