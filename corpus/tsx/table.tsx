// Composant générique de tableau : colonnes typées, accès indexé, map imbriqué.
interface Column<Row> {
  key: string;
  header: string;
  render: (row: Row) => string;
}

interface TableProps<Row> {
  rows: Row[];
  columns: Column<Row>[];
}

export function Table<Row>({ rows, columns }: TableProps<Row>) {
  return (
    <table>
      <thead>
        <tr>
          {columns.map((col) => (
            <th key={col.key}>{col.header}</th>
          ))}
        </tr>
      </thead>
      <tbody>
        {rows.map((row, i) => (
          <tr key={i}>
            {columns.map((col) => (
              <td key={col.key}>{col.render(row)}</td>
            ))}
          </tr>
        ))}
      </tbody>
    </table>
  );
}
