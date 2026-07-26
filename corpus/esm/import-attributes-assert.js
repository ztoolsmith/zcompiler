// `assert { … }` : l'ANCIEN mot-clé (import assertions), accepté en lecture
// comme alias déprécié — il traîne dans du code réel. Le printer le PRÉSERVE
// (un formateur ne réécrit pas la syntaxe de l'utilisateur dans son dos).
import config from './config.json' assert { type: 'json' };
import * as data from './data.json' assert { type: 'json' };
export { entries } from './entries.json' assert { type: 'json' };
export * as extra from './extra.json' assert { type: 'json' };

// Non-régression : `assert` et `with` restent des identifiants ordinaires
// partout ailleurs (aucun des deux n'est un mot-clé du lexer).
const assert = (c) => { if (!c) throw new Error('nope'); };
const o = { with: 1, assert: 2 };
assert(o.with === 1 && o.assert === 2);

export { config, data, assert, o };
