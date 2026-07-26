// Hook générique custom + tagged element + satisfies sur des props.
import { useState, useEffect } from "react";

function useLocalState<T>(key: string, initial: T): [T, (v: T) => void] {
  const [value, setValue] = useState<T>(initial);
  useEffect(() => {
    const raw = window.localStorage.getItem(key);
    if (raw != null) setValue(JSON.parse(raw) as T);
  }, [key]);
  return [value, setValue];
}

export function Toggle() {
  const [on, setOn] = useLocalState<boolean>("toggle", false);
  const style = { cursor: "pointer" } satisfies Record<string, string>;
  return (
    <span style={style} onClick={() => setOn(!on)}>
      {on ? "ON" : "OFF"}
    </span>
  );
}
