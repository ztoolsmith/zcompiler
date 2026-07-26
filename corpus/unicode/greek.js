const Ω = 3.14159;
let λ = (α, β) => α + β;
const Δ = λ(Ω, 2);
function σ(μ) { return μ / Δ; }
export { σ, Δ };
