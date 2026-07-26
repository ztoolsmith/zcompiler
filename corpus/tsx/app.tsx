// Composition réaliste : imports mixtes, état, générique d'appel, conditionnel.
import { useState } from "react";
import { Button } from "./button";
import type { ReactNode } from "react";

type Status = "idle" | "loading" | "done";

interface AppProps {
  title: string;
  footer?: ReactNode;
}

export default function App({ title, footer }: AppProps) {
  const [status, setStatus] = useState<Status>("idle");
  const items = Array.from<number>({ length: 3 } as ArrayLike<number>);
  return (
    <div className="app">
      <h1>{title}</h1>
      <Button label="Load" onClick={() => setStatus("loading")} />
      {status === "done" && <p>Terminé.</p>}
      <ul>
        {items.map((n, i) => (
          <li key={i}>{n}</li>
        ))}
      </ul>
      {footer}
    </div>
  );
}
