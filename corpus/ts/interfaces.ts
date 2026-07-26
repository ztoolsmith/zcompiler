// Interfaces : propriétés, optionnels, readonly, méthodes, extends.
interface Point {
  x: number;
  y: number;
}

interface Named {
  readonly id: number;
  name?: string;
}

interface Shape extends Point, Named {
  area(): number;
  scale(factor: number): Shape;
}

const origin: Point = { x: 0, y: 0 };
export { origin };
