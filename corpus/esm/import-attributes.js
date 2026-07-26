// Import attributes (ES2025) : `with { type: 'json' }`. La syntaxe qui permettra
// à un bundler de router les assets vers le bon loader.
import config from './config.json' with { type: 'json' };
import styles from './styles.css' with { type: 'css' };

// Side-effect + attributs (la forme la plus courante pour une feuille de style).
import './reset.css' with { type: 'css' };

// Namespace + attributs.
import * as data from './data.json' with { type: 'json' };

// Default + nommés + attributs.
import def, { named } from './mixed.json' with { type: 'json' };

// Sur un re-export, et sur un `export *`.
export { entries } from './entries.json' with { type: 'json' };
export * from './more.json' with { type: 'json' };
export * as extra from './extra.json' with { type: 'json' };

// Plusieurs entrées, clé string, virgule finale.
import multi from './multi.json' with { 'a-b': 'v', type: 'json', };

// import() dynamique avec son 2e argument (une expression, pas la clause `with`).
const lazy = () => import('./lazy.json', { with: { type: 'json' } });

export { config, styles, data, def, named, multi, lazy };
