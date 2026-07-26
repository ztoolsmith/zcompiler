# playground

Bac à sable pour lancer le parser [zparse](../packages/zparse) à la main, sur
tes propres entrées, sans écrire de test formel.

Il importe `zparse` via `workspace:*` : c'est donc le **même package** qu'un vrai
consommateur (le loader `index.js` + l'addon `zparse.node` générés par
`zignapi build`).

## Utilisation

```sh
# 1. builder zparse (compile l'addon + génère le loader)
pnpm --filter zparse build

# 2. lancer le playground
pnpm --filter playground start                 # exemples intégrés
pnpm --filter playground start "let x = 42;"   # ta propre entrée
# ou directement, depuis ce dossier :
node index.js "let x = 42;"
```

Rebuild zparse après chaque modif de la grammaire (`native/parser.zig`) ou de
ce qui est exposé (`native/main.zig`), puis relance le playground.
