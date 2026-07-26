// namespace simple : membres export const/function/class à un niveau.
namespace Geometry {
  export const PI = 3.14159;

  export function circleArea(r: number): number {
    return PI * r * r;
  }

  export class Circle {
    constructor(public radius: number) {}
    area(): number {
      return circleArea(this.radius);
    }
  }

  const helper = 42; // membre privé (non exporté)
}

const a = Geometry.circleArea(2);
const c = new Geometry.Circle(5);
export { a, c };
