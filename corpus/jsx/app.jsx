// Composition réaliste : hooks, état local, composants majuscules (références),
// balises intrinsèques (non-références).
import { useState, useCallback } from "react";
import { Button } from "./button";

export default function App({ initial = 0 }) {
  const [count, setCount] = useState(initial);
  const inc = useCallback(() => setCount((c) => c + 1), []);
  return (
    <div className="app">
      <h1>Compteur : {count}</h1>
      <Button label="+" onClick={inc} />
      {count > 10 && <p className="warn">C'est beaucoup !</p>}
    </div>
  );
}
