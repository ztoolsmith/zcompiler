// Refs typées, events, generic calls DOM, fragments.
import { useRef } from "react";

interface FieldProps {
  name: string;
  value: string;
  onChange: (value: string) => void;
}

function Field({ name, value, onChange }: FieldProps) {
  const ref = useRef<HTMLInputElement>(null);
  return (
    <>
      <label htmlFor={name}>{name}</label>
      <input
        ref={ref}
        id={name}
        value={value}
        onChange={(e) => onChange((e.target as HTMLInputElement).value)}
      />
    </>
  );
}

export { Field };
