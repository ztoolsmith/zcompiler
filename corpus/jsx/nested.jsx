// Imbrication profonde + composition de composants.
export function Layout({ header, children }) {
  return (
    <div className="layout">
      <header className="top">
        <nav>
          <ul>
            <li><a href="/">Accueil</a></li>
            <li><a href="/about">À propos</a></li>
          </ul>
        </nav>
        {header}
      </header>
      <main>{children}</main>
    </div>
  );
}
