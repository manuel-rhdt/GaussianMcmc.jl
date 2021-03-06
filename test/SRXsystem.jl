using Catalyst
using GaussianMcmc
using StaticArrays
using Test

sn = @reaction_network begin
    κ, ∅ --> 2L
    λ, L --> ∅
end κ λ

rn = @reaction_network begin
    ρ, L + R --> L + LR
    μ, LR --> R
    ξ, R + CheY --> R + CheYp
    ν, CheYp --> CheY
end ρ μ ξ ν

xn = @reaction_network begin
    δ, CheYp --> CheYp + X
    χ, X --> ∅
end δ χ

u0 = SA[10, 30, 0, 50, 0, 0]
dtimes = 0:0.5:10.0
ps = [5.0, 1.0]
pr = [1.0, 4.0, 1.0, 2.0]
px = [1.0, 1.0]

system = SRXsystem(sn, rn, xn, u0, ps, pr, px, dtimes)

algorithm = DirectMCEstimate(4_000)

result = mutual_information(system, algorithm, num_responses = 5)

for v in result[!, :MutualInformation]
    @test length(v) == length(system.dtimes)
end
