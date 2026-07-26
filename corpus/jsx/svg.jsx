// Namespaces JSX : svg:path, xlink:href (jamais des références).
export function Logo() {
  return (
    <svg viewBox="0 0 24 24" width={24} height={24}>
      <svg:path d="M12 2 L2 22 L22 22 Z" fill="currentColor" />
      <use xlink:href="#glyph" />
    </svg>
  );
}
