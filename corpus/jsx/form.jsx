// Éléments auto-fermants (`<input/>`, `<br />`), attributs booléens, nombres.
export function SignupForm({ onSubmit }) {
  return (
    <form onSubmit={onSubmit}>
      <input name="user" type="text" required maxLength={32} />
      <br />
      <input name="pass" type="password" required minLength={8} />
      <hr />
      <button type="submit">Créer le compte</button>
    </form>
  );
}
