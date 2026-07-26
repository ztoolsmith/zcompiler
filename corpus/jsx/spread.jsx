// Spread props {...rest}, attribut bare, mélange avec des attributs nommés.
export function Input(props) {
  const { value, ...rest } = props;
  return <input value={value} readOnly {...rest} className="input" />;
}

export function Passthrough(props) {
  return <Input {...props} autoFocus />;
}
