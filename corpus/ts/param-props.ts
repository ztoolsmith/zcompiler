// Parameter properties : modificateurs sur les params du constructeur.
class Point {
  constructor(
    public readonly x: number,
    public readonly y: number,
  ) {}

  distanceTo(other: Point): number {
    const dx = this.x - other.x;
    const dy = this.y - other.y;
    return Math.sqrt(dx * dx + dy * dy);
  }
}

class Widget extends Point {
  constructor(
    private label: string,
    x: number,
    y: number,
  ) {
    super(x, y);
    this.render();
  }

  private render(): void {
    console.log(this.label);
  }
}

const w = new Widget("btn", 1, 2);
export { Point, Widget, w };
