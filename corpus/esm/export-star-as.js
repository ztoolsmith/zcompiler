// `export * as ns from` (ES2020) — le pattern « barrel » : un index.js qui
// regroupe des sous-modules sous des namespaces. C'est zbundle qui a révélé
// que le parser ne le lisait pas.
export * as math from './math.js';
export * as strings from './strings.js';
export * as default from './default-ns.js';

// La forme nue cohabite avec la forme nommée.
export * from './shared.js';

// Et le reste des formes d'export, pour vérifier qu'on n'a rien cassé.
export { add, sub as minus } from './math.js';
export { helper };

const helper = () => math.add(1, 2);
export default helper;
