// errors: 1
// La valeur d'un attribut DOIT être une string (spec) : `json` nu est refusé.
// Le statement suivant doit survivre.
import cfg from './cfg.json' with { type: json };
const ok = 1;
