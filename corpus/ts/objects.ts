// Types objet inline, nommés, tableaux de types objet, fonctions membres.
type Vec2 = { x: number; y: number };
type Segment = { from: Vec2; to: Vec2; label?: string };

function length(seg: Segment): number {
  const dx: number = seg.to.x - seg.from.x;
  const dy: number = seg.to.y - seg.from.y;
  return Math.sqrt(dx * dx + dy * dy);
}

const path: Vec2[] = [
  { x: 0, y: 0 },
  { x: 3, y: 4 },
];

const config: { retries: number; onError: (e: string) => void } = {
  retries: 3,
  onError: (e) => console.error(e),
};

export { length, path, config };
