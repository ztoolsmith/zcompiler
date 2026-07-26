// La double nature : enum utilisé en position de TYPE et de VALEUR.
enum Suit {
  Hearts,
  Diamonds,
  Clubs,
  Spades,
}

interface Card {
  suit: Suit;
  rank: number;
}

function isRed(card: Card): boolean {
  return card.suit === Suit.Hearts || card.suit === Suit.Diamonds;
}

const deck: Card[] = [
  { suit: Suit.Hearts, rank: 1 },
  { suit: Suit.Spades, rank: 13 },
];

let start: Suit = Suit.Clubs;
export { Suit, isRed, deck, start };
