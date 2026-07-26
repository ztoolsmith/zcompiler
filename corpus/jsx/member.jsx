// Noms membres A.B.C : la racine est TOUJOURS une référence (même minuscule,
// ex. `motion.div` importé), les balises intrinsèques minuscules ne le sont pas.
import { motion } from "framer-motion";
import * as Icons from "./icons";

export function Card({ title }) {
  return (
    <motion.div className="card" animate={{ opacity: 1 }}>
      <Icons.Star size={16} />
      <h2>{title}</h2>
    </motion.div>
  );
}
