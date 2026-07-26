// Texte multiligne : les blancs/newlines sont des JSXText (aucun trimming ici,
// c'est le boulot du transformer React, pas du parser).
export function Prose() {
  return (
    <article>
      Bonjour le monde. Ceci est un paragraphe qui court
      sur plusieurs lignes, avec {"des"} expressions au milieu
      et encore du texte après.
    </article>
  );
}
