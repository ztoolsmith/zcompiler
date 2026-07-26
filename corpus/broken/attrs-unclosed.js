// errors: 1
// Clause `with` non fermée : panic mode + synchronisation, les statements
// sains d'après survivent.
import a from './a.json' with { type: 'json'
const ok = 1;
const also = 2;
