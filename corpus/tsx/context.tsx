// Contexte générique, provider, as casts sur du JSX.
import { createContext, useContext } from "react";

interface Theme {
  color: string;
  dark: boolean;
}

const ThemeContext = createContext<Theme>({ color: "black", dark: false });

export function useTheme(): Theme {
  return useContext(ThemeContext);
}

export function ThemeProvider({ value, children }: { value: Theme; children: unknown }) {
  const Provider = ThemeContext.Provider;
  return <Provider value={value}>{children as JSX.Element}</Provider>;
}
