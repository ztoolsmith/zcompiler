// Composant simple : props, className, handler, enfant texte.
import React from "react";

export function Button({ label, onClick, disabled }) {
  return (
    <button className="btn" type="button" onClick={onClick} disabled={disabled}>
      {label}
    </button>
  );
}
