// errors: 1
// survives: ) du switch recuperee ; after() survit
switch (x {
  case 1: a(); break;
}
after();
