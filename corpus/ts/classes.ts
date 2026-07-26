// Classe : héritage, implements, champs statiques/typés, méthodes, accesseurs.
interface Comparable {
  compareTo(other: this): number;
}

abstract class Base {
  protected createdAt: number = Date.now();
}

class Money extends Base implements Comparable {
  static readonly currency: string = "EUR";
  private amount: number;

  constructor(amount: number) {
    super();
    this.amount = amount;
  }

  compareTo(other: Money): number {
    return this.amount - other.amount;
  }

  add(other: Money): Money {
    return new Money(this.amount + other.amount);
  }
}

export { Money };
