import Catalyst
import Catalyst:@reaction_network
import ModelingToolkit
using Transducers

function gene_expression_system(; mean_s=50, corr_time_s=1.0, corr_time_x=0.1, dtimes=0:0.1:2.0)
    sn = @reaction_network begin
        κ, ∅ --> S
        λ, S --> ∅
    end κ λ

    xn = @reaction_network begin
        ρ, S --> X + S
        μ, X --> ∅ 
    end ρ μ

    λ = 1 / corr_time_s
    κ = mean_s * λ
    μ = 1 / corr_time_x
    ρ = μ
    mean_x = mean_s

    u0 = SA[mean_s, mean_x]
    ps = [κ, λ]
    px = [ρ, μ]

    SXsystem(sn, xn, u0, ps, px, dtimes)
end

function chemotaxis_system(; 
        mean_L=20, 
        num_receptors=10000, 
        Y_tot=5000, 
        L_timescale=1.0, 
        LR_timescale=0.01, 
        LR_ratio=0.5, 
        Y_timescale=0.1, 
        Y_ratio=1/6, 
        q=0, 
        dtimes=0:0.1:2.0
    )
    mean_LR = num_receptors * LR_ratio
    mean_R = num_receptors - mean_LR

    mean_Yp = Y_tot * Y_ratio
    mean_Y = Y_tot - mean_Yp

    eq_L = mean_L * exp(-q)

    sn = @reaction_network begin
        κ, ∅ --> L
        λ, L --> ∅
    end κ λ

    rn = @reaction_network begin
        ρ, L + R --> L + LR
        μ, LR --> R
    end ρ μ

    xn = @reaction_network begin
        δ, LR + Y --> Yp + LR
        χ, Yp --> Y
    end δ χ

    u0 = round.([mean_L, mean_R, mean_LR, mean_Y, mean_Yp])
    ps = [mean_L, 1 / L_timescale]

    ρ = inv(eq_L * LR_timescale * (1 + mean_R / mean_LR))
    μ = eq_L * ρ * mean_R / mean_LR

    pr = [ρ, μ]

    χ = inv(Y_timescale * (1 + Y_ratio))
    δ = χ * Y_ratio / mean_LR

    px = [δ, χ]

    SRXsystem(sn, rn, xn, u0, ps, pr, px, dtimes)
end

function chemotaxis_parameters(;
    E₀ = 0.0,
    Kₐ = 500,
    Kᵢ = 25,
    δg = log(Kₐ/Kᵢ),
    δf = -0.5,
    k⁺ = 0.05,
    k⁺ₐ = k⁺,
    k⁺ᵢ = k⁺,
    k⁻ₐ = Kₐ * k⁺ₐ,
    k⁻ᵢ = Kᵢ * k⁺ᵢ,
    a_star = 0.8,
    γ = 1 / 5,
    k_B = (1 - a_star) * γ / abs(δf),
    k_R =      a_star  * γ / abs(δf)
)
    [
        E₀,
        δg,
        δf,
        k⁺ₐ,
        k⁺ᵢ,
        k⁻ₐ,
        k⁻ᵢ,
        k_B,
        k_R
    ]
end

function cooperative_chemotaxis_system(;
    lmax = 3,
    mmax = 9,
    n_clusters = 100,
    n_chey = 10_000,

    mean_l = 50,

    phosphorylate = 2000.0 / (n_chey * n_clusters),
    dephosphorylate = 2000.0 / (n_chey),
    dtimes = 0:0.1:20.0,
    varargs...
)
    sn = @reaction_network begin
        κ, ∅ --> L
        λ, L --> ∅
    end κ λ

    rn = Catalyst.make_empty_network()

    @Catalyst.parameters t E0 δg δf lba lbi lda ldi mda mbi ρ
    @Catalyst.variables L(t) Y(t) Yp(t)

    Catalyst.addspecies!(rn, L)

    Catalyst.addparam!(rn, E0)
    Catalyst.addparam!(rn, δg)
    Catalyst.addparam!(rn, δf)
    Catalyst.addparam!(rn, lba)
    Catalyst.addparam!(rn, lbi)
    Catalyst.addparam!(rn, lda)
    Catalyst.addparam!(rn, ldi)
    Catalyst.addparam!(rn, mda)
    Catalyst.addparam!(rn, mbi)

    xn = @reaction_network begin
        μ, Yp --> Y
    end μ

    Catalyst.addparam!(xn, ρ)

    spmap = Dict()
    for l=0:lmax, m=0:mmax
        receptor_species = ModelingToolkit.Num(ModelingToolkit.Variable{ModelingToolkit.FnType{Tuple{Any},Real}}(Symbol("R_", l, "_", m)))(t)

        spmap[(l, m)] = receptor_species

        Catalyst.addspecies!(xn, receptor_species)
        Catalyst.addspecies!(rn, receptor_species)
    end

    p_active(l, m) = 1 / (1 + exp(E0 + l*δg + m*δf))

    for l=0:lmax, m=0:mmax

        if l > 0
            ligand_bind = Catalyst.Reaction((lba * p_active(l-1, m) + lbi * (1 - p_active(l-1, m))) * (lmax + 1 - l), [spmap[(l-1, m)], L], [spmap[(l, m)], L])
            ligand_unbind = Catalyst.Reaction((lda * p_active(l, m) + ldi * (1 - p_active(l, m))) * l, [spmap[(l, m)]], [spmap[(l-1, m)]])
            Catalyst.addreaction!(rn, ligand_bind)
            Catalyst.addreaction!(rn, ligand_unbind)
        end

        if m > 0
            demethylate_active = Catalyst.Reaction(mda * p_active(l, m), [spmap[(l, m)]], [spmap[(l, m-1)]])
            methylate_inactive = Catalyst.Reaction(mbi * (1 - p_active(l, m-1)), [spmap[(l, m-1)]], [spmap[(l, m)]])

            Catalyst.addreaction!(rn, demethylate_active)
            Catalyst.addreaction!(rn, methylate_inactive)
        end


        # every receptor phosphorylates Y with rate ρ if the receptor is active
        # if the receptor is inactive, no phosphorylation can happen
        receptor = spmap[(l, m)]
        phosphorylation = Catalyst.Reaction(ρ * p_active(l, m), [Y, receptor], [Yp, receptor])
        Catalyst.addreaction!(xn, phosphorylation)
    end

    joint = merge(merge(sn, rn), xn)

    u0 = zeros(Int, length(spmap) + 3)
    u0[1] = round(Int, mean_l)
    u0[Catalyst.speciesmap(joint)[spmap[(0, 0)]]] = n_clusters
    u0[Catalyst.speciesmap(joint)[Y]] = n_chey

    ps = [mean_l, 1.0]
    pr = chemotaxis_parameters(; varargs...)
    px = [dephosphorylate, phosphorylate]

    SRXsystem(sn, rn, xn, u0, ps, pr, px, dtimes; aggregator=DiffEqJump.RSSACR())
end

getname(sym) = String(ModelingToolkit.operation(sym).name)

function parse_receptor(species)
    sname = getname(species)
    mtch = match(r"([A-Z])_(\d+)_(\d+)", sname)
    if mtch !== nothing
        l = parse(Int, mtch.captures[2])
        m = parse(Int, mtch.captures[3])
        (l, m)
    else
        nothing
    end
end

function receptor_states(rs::ReactionSystem)
    smap = Catalyst.speciesmap(rs)
    xf = KeepSomething() do (species, index) 
        result = parse_receptor(species)
        if result === nothing
            nothing
        else
            result => index
        end
    end
    smap |> xf
end

receptor_states(system::SRXsystem) = receptor_states(reaction_network(system))

function active_receptors(conf::SRXconfiguration, system::SRXsystem)
    rstates = receptor_states(system)

    E0 = system.pr[1]
    δg = system.pr[2]
    δf = system.pr[3]

    p_active(l, m) = 1 / (1 + exp(E0 + l*δg + m*δf))

    p_a = rstates |> Map(((l, m), i)::Pair -> i => p_active(l, m)) |> collect

    f = function(u)
        sum(p_a) do (i, p)
            p * u[i]
        end
    end

    merge_trajectories(conf.s_traj, conf.r_traj, conf.x_traj) |> Map((u,t,i)::Tuple -> (ensurevec(f(u)),t,i)) |> collect_trajectory
end

precompile(gene_expression_system, ())
precompile(chemotaxis_system, ())
precompile(cooperative_chemotaxis_system, ())
