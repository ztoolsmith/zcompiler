// Composant typé : props interface, handler, enfant.
import type { ReactNode } from "react";

interface ButtonProps {
  label: string;
  onClick: () => void;
  disabled?: boolean;
  children?: ReactNode;
}

export function Button({ label, onClick, disabled }: ButtonProps): JSX.Element {
  return (
    <button className="btn" type="button" onClick={onClick} disabled={disabled}>
      {label}
    </button>
  );
}
