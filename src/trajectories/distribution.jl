import ModelingToolkit
import ModelingToolkit: build_function, ReactionSystem, substitute
import Catalyst

struct ChemicalReaction{Rate,N}
    rate::Rate
    netstoich::SVector{N,Int}
end

struct TrajectoryDistribution{Reactions,Dist}
    reactions::Reactions
    log_p0::Dist
end

distribution(rn::ReactionSystem) = distribution(rn, (x...) -> 0.0)
distribution(rn::ReactionSystem, log_p0) = TrajectoryDistribution(create_chemical_reactions(rn), log_p0)

@fastmath function Distributions.logpdf(dist::TrajectoryDistribution{<:Tuple}, trajectory; params=[])::Float64
    ((uprev, tprev), state) = iterate(trajectory)
    result = dist.log_p0(uprev...)::Float64
    
    for (u, t) in Iterators.rest(trajectory, state)
        dt = t - tprev
        du = u - uprev

        totalrate = evaltotalrate(uprev, dist.reactions..., params=params)

        result -= dt * totalrate
        reaction_rate = evalrxrate(uprev, du, dist.reactions..., params=params)
        if reaction_rate == zero(reaction_rate)
            return -Inf
        end
        result += log(reaction_rate)

        tprev = t
        uprev = copy(u)
    end

    result
end

function create_chemical_reactions(reaction_system::ReactionSystem)
    _create_chemical_reactions(reaction_system, Catalyst.reactions(reaction_system)...)
end

function var2name(var)
    ModelingToolkit.operation(var).name
end

function _create_chemical_reactions(rn::ReactionSystem, r1::Catalyst.Reaction)
    smap = Catalyst.speciesmap(rn)
    spec = var2name.(Catalyst.species(rn))
    ratelaw = substitute(Catalyst.jumpratelaw(r1), Dict(Catalyst.species(rn) .=> spec))

    rate_fun = build_function(ratelaw, spec, Catalyst.params(rn))
    rate_fun = eval(rate_fun)

    netstoich = [(smap[sub], stoich) for (sub, stoich) in r1.netstoich]

    du = zero(SVector{Catalyst.numspecies(rn),Int})
    for (index, netstoich) in netstoich
        du = setindex(du, netstoich, index)
    end

    (ChemicalReaction(rate_fun, du),)
end

function _create_chemical_reactions(rn::ReactionSystem, r1::Catalyst.Reaction, rs::Catalyst.Reaction...)
    (_create_chemical_reactions(rn, r1)..., _create_chemical_reactions(rn, rs...)...)
end

@inline @fastmath function evalrxrate(speciesvec::AbstractVector, reaction::ChemicalReaction, params=[])::Float64
    (reaction.rate)(speciesvec, params)
end

@inline function evalrxrate(speciesvec::AbstractVector, du::AbstractVector; params=[])::Float64
    1.0 # return 1.0 in this case since log(1) = 0.
end

@inline @fastmath function evalrxrate(speciesvec::AbstractVector, du::AbstractVector, r1::ChemicalReaction, rs::ChemicalReaction...; params=[])::Float64
    if du == r1.netstoich
        return evalrxrate(speciesvec, r1, params)
    else
        return evalrxrate(speciesvec, du, rs..., params=params)
    end
end

function evaltotalrate(speciesvec::AbstractVector, r1::ChemicalReaction; params=[])::Float64
    evalrxrate(speciesvec, r1, params)
end

function evaltotalrate(speciesvec::AbstractVector, r1::ChemicalReaction, rs::ChemicalReaction...; params=[])::Float64
    evalrxrate(speciesvec, r1, params) + evaltotalrate(speciesvec, rs..., params=params)
end

