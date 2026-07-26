// Enums string (pas de reverse mapping) + enum mixte.
enum Color {
  Red = "red",
  Green = "green",
  Blue = "blue",
}

enum Media {
  Image = "image",
  Video = "video",
}

function toHex(c: Color): string {
  const map: Record<Color, string> = {
    [Color.Red]: "#f00",
    [Color.Green]: "#0f0",
    [Color.Blue]: "#00f",
  };
  return map[c];
}

let current: Color = Color.Red;
export { Color, Media, toHex, current };
