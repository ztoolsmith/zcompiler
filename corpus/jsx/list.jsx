// map imbriqué : la double bascule JS -> JSX -> JS.
export function List({ items }) {
  return (
    <ul className="list">
      {items.map((item) => (
        <li key={item.id} data-id={item.id}>
          {item.name}
        </li>
      ))}
    </ul>
  );
}
