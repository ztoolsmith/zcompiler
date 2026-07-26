// async/await typé, Promise, types fonction async.
type Fetcher<T> = (url: string) => Promise<T>;

async function loadJson<T>(url: string): Promise<T> {
  const res = await fetch(url);
  const data: T = await res.json();
  return data;
}

const loadUsers: Fetcher<string[]> = async (url) => {
  const names: string[] = await loadJson(url);
  return names.filter((n) => n.length > 0);
};

export { loadJson, loadUsers };
