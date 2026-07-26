// errors: 1
// survives: la déclaration `ok` après l'attribut malformé
const broken = <div className= >texte</div>;
const ok = 1;
