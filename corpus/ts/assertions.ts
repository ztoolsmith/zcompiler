// as / satisfies / non-null / as const.
const raw: unknown = JSON.parse("{}");
const config = raw as { debug: boolean };
const flag = (config as any).debug as boolean;

const palette = { red: "#f00", green: "#0f0" } satisfies Record<string, string>;
const mode = "dark" as const;

function firstChar(s: string | null): string {
  return s!.charAt(0);
}

const doubled = firstChar("hi")!;
export { config, flag, palette, mode, doubled };
