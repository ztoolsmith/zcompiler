// Toutes les formes d'attributs : string, {expr}, élément JSX comme valeur,
// bare, namespacé, tiret (data-/aria-).
export function Field() {
  return (
    <label
      htmlFor="email"
      className={"field " + "large"}
      data-testid="email-field"
      aria-required
      icon={<Icon name="mail" />}
      style={{ color: "red", padding: 4 }}
    >
      E-mail
    </label>
  );
}
