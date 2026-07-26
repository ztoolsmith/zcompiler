// Conteneurs vides `{}` et commentaires `{/* … */}` (expression null, légal).
export function Placeholder({ ready, children }) {
  return (
    <section>
      {/* rien tant que ce n'est pas prêt */}
      {ready ? children : {}}
      <footer>{}</footer>
    </section>
  );
}
