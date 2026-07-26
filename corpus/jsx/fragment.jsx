// Fragments : <>…</> et enfants mixtes.
export function Columns({ left, right }) {
  return (
    <>
      <div className="col">{left}</div>
      <div className="col">{right}</div>
    </>
  );
}

export const Wrapped = () => <>{[1, 2, 3].map((n) => <span>{n}</span>)}</>;
