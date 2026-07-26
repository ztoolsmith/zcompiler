// Hooks typés, état, callbacks, rendu conditionnel.
import { useState, useCallback } from "react";

type CounterProps = { initial?: number; step?: number };

export default function Counter({ initial = 0, step = 1 }: CounterProps) {
  const [count, setCount] = useState<number>(initial);
  const inc = useCallback(() => setCount((c) => c + step), [step]);
  const dec = useCallback(() => setCount((c) => c - step), [step]);
  return (
    <div className="counter">
      <button onClick={dec}>-</button>
      <span>{count}</span>
      <button onClick={inc}>+</button>
      {count > 10 ? <p className="warn">Grand !</p> : null}
    </div>
  );
}
