// catch typé (`e: unknown`), narrowing, tuples, fonction imbriquée.
function parseSafe(text: string): [boolean, unknown] {
  try {
    const value: unknown = JSON.parse(text);
    return [true, value];
  } catch (err: unknown) {
    const message: string = err instanceof Error ? err.message : "unknown";
    return [false, message];
  }
}

const [ok, result] = parseSafe("{}");
export { parseSafe, ok, result };
