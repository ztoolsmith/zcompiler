// Annotations de type : variables, params, retours, optionnels.
let count: number = 0;
const name: string = "zparse";
let ready: boolean;

function greet(who: string, loud?: boolean): string {
  const suffix: string = loud ? "!" : ".";
  return "hello " + who + suffix;
}

const add = (a: number, b: number): number => a + b;
const pair: [string, number] = ["x", 1];

export { count, name, greet, add, pair };
