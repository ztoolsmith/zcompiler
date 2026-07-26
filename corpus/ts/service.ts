// Un service typé : classe générique, champs, méthodes, modifieurs d'accès.
interface Entity {
  id: number;
}

class Repository<T extends Entity> {
  private items: T[] = [];
  readonly name: string;

  constructor(name: string) {
    this.name = name;
  }

  add(item: T): void {
    this.items.push(item);
  }

  findById(id: number): T | undefined {
    return this.items.find((it) => it.id === id);
  }

  get size(): number {
    return this.items.length;
  }
}

const users = new Repository("users");
users.add({ id: 1 });
export { Repository, users };
