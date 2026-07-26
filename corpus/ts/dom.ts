// Génériques d'appel typiques du DOM/navigateur + comparaisons voisines.
const el = document.querySelector<HTMLInputElement>("#name");
const items = document.querySelectorAll<HTMLLIElement>("li");

function clamp(value: number, min: number, max: number): number {
  return value < min ? min : value > max ? max : value;
}

const arr = Array.from<number>([1, 2, 3]);
const width = el ? el.clientWidth : 0;

// Piège classique : `a < b, c > d` = deux comparaisons, pas un générique.
const flags = [width < 100, items.length > 0];
export { clamp, arr, flags };
