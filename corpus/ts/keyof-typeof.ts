// keyof / typeof en position de type + noms qualifiés.
const settings = { theme: "dark", size: 12, verbose: false };

type Settings = typeof settings;
type SettingKey = keyof Settings;

function get(key: SettingKey): string | number | boolean {
  return settings[key];
}

let theme: typeof settings.theme = "light";
export { get, theme };
