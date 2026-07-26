// Accès indexé T[K] + index signatures (phase 2).
interface Config {
  host: string;
  port: number;
  flags: { [name: string]: boolean };
}

type Host = Config["host"];
type Value = Config[keyof Config];

type Dict = { [key: string]: number };
type ReadonlyDict = { readonly [key: string]: string };

function getFlag(cfg: Config, name: string): boolean {
  return cfg.flags[name];
}

const port: Config["port"] = 8080;
export { getFlag, port };
