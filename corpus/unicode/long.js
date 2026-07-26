function traiter(données, résultat) {
  const café_chaud = données.map(élément => élément.valeur * 2);
  let 合計 = 0;
  for (const 項目 of café_chaud) { 合計 += 項目; }
  return résultat(合計, café_chaud);
}
export { traiter };
