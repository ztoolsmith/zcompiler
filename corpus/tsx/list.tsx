// Props génériques + hook useState<T> + map JSX.
import { useState } from "react";

interface ListProps<T> {
  items: T[];
  render: (item: T) => string;
}

export function List<T>({ items, render }: ListProps<T>) {
  const [selected, setSelected] = useState<number>(-1);
  return (
    <ul className="list">
      {items.map((item, i) => (
        <li key={i} data-active={i === selected} onClick={() => setSelected(i)}>
          {render(item)}
        </li>
      ))}
    </ul>
  );
}
