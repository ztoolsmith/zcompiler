// Rendu conditionnel : ternaire et court-circuit avec du JSX imbriqué.
export function Status({ loading, error, data }) {
  return (
    <div className="status">
      {loading ? <Spinner /> : null}
      {error && <p className="err">{error.message}</p>}
      {data ? <pre>{JSON.stringify(data)}</pre> : <em>aucune donnée</em>}
    </div>
  );
}
