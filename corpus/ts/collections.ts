// Génériques chaînés réalistes : builders, promesses, réductions.
async function fetchAll<T>(urls: string[]): Promise<T[]> {
  const results = await Promise.all<T>(urls.map((u) => fetch(u).then((r) => r.json())));
  return results;
}

class Stack<T> {
  private items: T[] = [];
  push(x: T): void {
    this.items.push(x);
  }
  pop(): T | undefined {
    return this.items.pop();
  }
  map<U>(fn: (x: T) => U): Stack<U> {
    const out = new Stack<U>();
    for (const it of this.items) out.push(fn(it));
    return out;
  }
}

const s = new Stack<number>();
s.push(1);
const doubled = s.map<number>((x) => x * 2);
export { fetchAll, Stack, doubled };
