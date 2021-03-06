import Distributions:logpdf
using Transducers
using DiffEqJump

struct MarginalEnsemble{JP<:DiffEqBase.AbstractJumpProblem}
    jump_problem::JP
    dist::TrajectoryDistribution
    dtimes::Vector{Float64}
end

struct ConditionalEnsemble{JP<:DiffEqBase.AbstractJumpProblem,IX,DX}
    jump_problem::JP
    dist::TrajectoryDistribution
    indep_idxs::IX
    dep_idxs::DX
    dtimes::Vector{Float64}
end

struct SXconfiguration{uTs,uTx,tType}
    s_traj::Trajectory{uTs,tType}
    x_traj::Trajectory{uTx,tType}
end

Base.copy(c::SXconfiguration) = SXconfiguration(copy(c.s_traj), copy(c.x_traj))
struct SRXconfiguration{uTs,Utr,Utx,tType}
    s_traj::Trajectory{uTs,tType}
    r_traj::Trajectory{Utr,tType}
    x_traj::Trajectory{Utx,tType}
end

Base.copy(c::SRXconfiguration) = SXconfiguration(copy(c.s_traj), copy(c.r_traj), copy(c.x_traj))

ensurevec(a::AbstractVector) = a
ensurevec(a) = SVector(a)

function Base.getindex(conf::SXconfiguration, index)
    merge_trajectories(conf.s_traj, conf.x_traj) |> Map((u,t,i)::Tuple -> (ensurevec(u[index]),t,i)) |> Thin() |> collect_trajectory
end

function Base.getindex(conf::SRXconfiguration, index)
    merge_trajectories(conf.s_traj, conf.r_traj, conf.x_traj) |> Map((u,t,i)::Tuple -> (ensurevec(u[index]),t,i)) |> Thin() |> collect_trajectory
end

abstract type JumpNetwork end
struct SXsystem <: JumpNetwork
    sn::ReactionSystem
    xn::ReactionSystem

    u0::AbstractVector

    ps::AbstractVector
    px::AbstractVector

    dtimes

    jump_problem
    dist::TrajectoryDistribution
end

function SXsystem(sn, xn, u0, ps, px, dtimes, dist=nothing)
    joint = merge(sn, xn)

    tp = (first(dtimes), last(dtimes))
    p = vcat(ps, px)
    dprob = DiscreteProblem(joint, copy(u0), tp, p)
    jprob = JumpProblem(convert(ModelingToolkit.JumpSystem, joint), dprob, Direct(), save_positions=(false, false))

    if dist === nothing
        update_map = build_update_map(joint, xn)
        dist = distribution(joint, p; update_map)
    end

    SXsystem(sn, xn, u0, ps, px, dtimes, jprob, dist)
end

struct CompiledSXsystem{JP}
    system::SXsystem
    marginal_ensemble::MarginalEnsemble{JP}
end

compile(s::SXsystem) = CompiledSXsystem(s, MarginalEnsemble(s))
marginal_density(csx::CompiledSXsystem, algorithm, conf::SXconfiguration) = log_marginal(simulate(algorithm, conf, csx.marginal_ensemble))
conditional_density(csx::CompiledSXsystem, algorithm, conf::SXconfiguration) = -energy_difference(conf, csx.marginal_ensemble)

struct SRXsystem <: JumpNetwork
    sn::ReactionSystem
    rn::ReactionSystem
    xn::ReactionSystem

    u0::AbstractVector

    ps::AbstractVector
    pr::AbstractVector
    px::AbstractVector

    dtimes

    jump_problem
    dist::TrajectoryDistribution
end

function SRXsystem(sn, rn, xn, u0, ps, pr, px, dtimes, dist=nothing; aggregator=Direct())
    joint = merge(merge(sn, rn), xn)

    tp = (first(dtimes), last(dtimes))
    p = vcat(ps, pr, px)
    dprob = DiscreteProblem(joint, copy(u0), tp, p)
    jprob = JumpProblem(convert(ModelingToolkit.JumpSystem, joint), dprob, aggregator, save_positions=(false, false))

    if dist === nothing
        update_map = build_update_map(joint, xn)
        dist = distribution(joint, p; update_map)
    end

    SRXsystem(sn, rn, xn, u0, ps, pr, px, dtimes, jprob, dist)
end

struct CompiledSRXsystem{JP, JPC, IXC, DXC}
    system::SRXsystem
    marginal_ensemble::MarginalEnsemble{JP}
    conditional_ensemble::ConditionalEnsemble{JPC, IXC, DXC}
end

compile(s::SRXsystem) = CompiledSRXsystem(s, MarginalEnsemble(s), ConditionalEnsemble(s))
marginal_density(csrx::CompiledSRXsystem, algorithm, conf::SRXconfiguration) = log_marginal(simulate(algorithm, marginal_configuration(conf), csrx.marginal_ensemble))
conditional_density(csrx::CompiledSRXsystem, algorithm, conf::SRXconfiguration) = log_marginal(simulate(algorithm, conf, csrx.conditional_ensemble))

tspan(sys::JumpNetwork) = (first(sys.dtimes), last(sys.dtimes))

reaction_network(system::SXsystem) = merge(system.sn, system.xn)
reaction_network(system::SRXsystem) = merge(merge(system.sn, system.rn), system.xn)

function _solve(system::SXsystem)
    sol = solve(system.jump_problem, SSAStepper())
end

function generate_configuration(system::SXsystem)
    joint = reaction_network(system)
    jp = remake(system.jump_problem, u0=copy(system.u0))
    integrator = init(jp, SSAStepper(), tstops=())
    trajectory_iter = SSAIter(integrator)
    trajectory = trajectory_iter |> collect_trajectory


    s_spec = independent_species(system.sn)
    s_idxs = sort(SVector(species_indices(joint, s_spec)...))
    s_traj = sub_trajectory(trajectory, s_idxs)

    x_spec = independent_species(system.xn)
    x_idxs = sort(SVector(species_indices(joint, x_spec)...))
    x_traj = sub_trajectory(trajectory, x_idxs)

    SXconfiguration(s_traj, x_traj)
end

function _solve(system::SRXsystem)
    sol = solve(system.jump_problem, SSAStepper())
end

function generate_configuration(system::SRXsystem)
    # we first generate a joint SRX trajectory
    joint = reaction_network(system)
    jp = remake(system.jump_problem, u0=copy(system.u0))
    integrator = init(jp, SSAStepper(), tstops=())
    trajectory = SSAIter(integrator) |> collect_trajectory

    # then we extract the signal
    s_spec = independent_species(system.sn)
    s_idxs = sort(SVector(species_indices(joint, s_spec)...))
    s_traj = sub_trajectory(trajectory, s_idxs)

    # the R trajectory
    r_spec = independent_species(system.rn)
    r_idxs = sort(SVector(species_indices(joint, r_spec)...))
    r_traj = sub_trajectory(trajectory, r_idxs)
    
    # finally we extract the X part from the SRX trajectory
    x_spec = independent_species(system.xn)
    x_idxs = sort(SVector(species_indices(joint, x_spec)...))
    x_traj = sub_trajectory(trajectory, x_idxs)

    SRXconfiguration(s_traj, r_traj, x_traj)
end

function build_update_map(joint::ReactionSystem, xn::ReactionSystem)
    update_map = Int[]
    spmap = Catalyst.speciesmap(joint)
    mapper = (x, y)::Pair -> spmap[x] => y

    unique_netstoich = unique(map(r -> mapper.(r.netstoich), Catalyst.reactions(xn)))

    for react in Catalyst.reactions(joint)
        new_index = 0
        for (k, un) in enumerate(unique_netstoich)
            if mapper.(react.netstoich) == un
                new_index = k
                break
            end
        end

        push!(update_map, new_index)
    end
    update_map
end

function MarginalEnsemble(system::SXsystem)
    joint = reaction_network(system)
    s_idxs = species_indices(joint, Catalyst.species(system.sn))

    dprob = DiscreteProblem(system.sn, system.u0[s_idxs], tspan(system), system.ps)
    jprob = JumpProblem(convert(ModelingToolkit.JumpSystem, system.sn), dprob, Direct(), save_positions=(false, false))

    MarginalEnsemble(jprob, system.dist, collect(system.dtimes))
end

function MarginalEnsemble(system::SRXsystem)
    sr_network = merge(system.sn, system.rn)
    joint = merge(sr_network, system.xn)
    sr_idxs = species_indices(joint, Catalyst.species(sr_network))

    dprob = DiscreteProblem(sr_network, system.u0[sr_idxs], tspan(system), vcat(system.ps, system.pr))
    jprob = JumpProblem(convert(ModelingToolkit.JumpSystem, sr_network), dprob, Direct(), save_positions=(false, false))

    MarginalEnsemble(jprob, system.dist, collect(system.dtimes))
end
mutable struct TrajectoryCallback{uType,tType}
    traj::Trajectory{uType,tType}
    index::Int
end

TrajectoryCallback(traj::Trajectory) = TrajectoryCallback(traj, 1)

function (tc::TrajectoryCallback)(integrator::DiffEqBase.DEIntegrator) # affect!
    traj = tc.traj
    tc.index = min(tc.index + 1, length(tc.traj.t))
    cond_u = traj.u[tc.index]
    for i in eachindex(cond_u)
        integrator.u[i] = cond_u[i]
    end
    # it is important to call this to properly update reaction rates
    DiffEqJump.reset_aggregated_jumps!(integrator, nothing, integrator.cb)
    nothing
end

function (tc::TrajectoryCallback)(u, t::Real, i::DiffEqBase.DEIntegrator)::Bool # condition
    @inbounds tcb = tc.traj.t[tc.index]
    while tc.index < length(tc.traj.t) && t > tcb
        tc.index += 1
        @inbounds tcb = tc.traj.t[tc.index]
    end
    t == tcb
end


function ConditionalEnsemble(system::SRXsystem)
    joint = merge(merge(system.sn, system.rn), system.xn)
    r_idxs = species_indices(joint, Catalyst.species(system.rn))
    dprob = DiscreteProblem(system.rn, system.u0[r_idxs], (first(system.dtimes), last(system.dtimes)), system.pr)
    jprob = JumpProblem(convert(ModelingToolkit.JumpSystem, system.rn), dprob, Direct(), save_positions=(false, false))

    indep_species = independent_species(system.rn)
    indep_idxs = species_indices(system.rn, indep_species)

    dep_species = dependent_species(system.xn)
    dep_idxs = indexin(species_indices(system.rn, dep_species), indep_idxs)

    ConditionalEnsemble(jprob, system.dist, indep_idxs, dep_idxs, collect(system.dtimes))
end

# returns a list of species in `a` that also occur in `b`
function intersecting_species(a::ReactionSystem, b::ReactionSystem)
    intersect(Catalyst.species(a), Catalyst.species(b))
end

# returns a list of species in `a` that are not in `b`
function unique_species(a::ReactionSystem, b::ReactionSystem)
    setdiff(Catalyst.species(a), Catalyst.species(b))
end

function species_indices(rs::ReactionSystem, species)
    getindex.(Ref(Catalyst.speciesmap(rs)), species)
end

function independent_species(rs::ReactionSystem)
    i_spec = []
    for r in Catalyst.reactions(rs)
        push!(i_spec, getindex.(r.netstoich, 1)...)
    end
    unique(s for s∈i_spec)
end

function dependent_species(rs::ReactionSystem)
    setdiff(Catalyst.species(rs), independent_species(rs))
end

function sample(configuration::T, system::MarginalEnsemble; θ=0.0)::T where T <: SXconfiguration
    if θ != 0.0
        error("can only use DirectMC with JumpNetwork")
    end
    jprob = system.jump_problem
    integrator = DiffEqBase.init(jprob, SSAStepper(), tstops=(), numsteps_hint=0)
    iter = SSAIter(integrator)
    s_traj = collect_trajectory(iter)
    SXconfiguration(s_traj, configuration.x_traj)
end

function collect_samples(initial::SXconfiguration, ensemble::MarginalEnsemble, num_samples::Int)
    jprob = ensemble.jump_problem
    integrator = DiffEqBase.init(jprob, SSAStepper(), tstops=(), numsteps_hint=0)

    result = Array{Float64,2}(undef, length(ensemble.dtimes), num_samples)
    for result_col ∈ eachcol(result)
        integrator = DiffEqBase.init(jprob, SSAStepper(), tstops=(), numsteps_hint=0)
        iter = SSAIter(integrator) |> Map((u,t,i)::Tuple -> (u,t,0))
        cumulative_logpdf!(result_col, ensemble.dist, merge_trajectories(iter, initial.x_traj), ensemble.dtimes)
    end

    result
end

function propagate(conf::SXconfiguration, ensemble::MarginalEnsemble, u0, tspan::Tuple)
    jprob = remake(ensemble.jump_problem, u0=u0, tspan=tspan)
    integrator = DiffEqBase.init(jprob, SSAStepper(), tstops=(), numsteps_hint=0)

    ix1 = max(searchsortedfirst(conf.x_traj.t, tspan[1])-1, 1)

    iter = SSAIter(integrator) |> Map((u,t,i)::Tuple -> (u,t,0))
    log_weight = trajectory_energy(ensemble.dist, iter |> MergeWith(conf.x_traj, ix1), tspan=tspan)

    copy(integrator.u), log_weight
end

function energy_difference(configuration::SXconfiguration, ensemble::MarginalEnsemble)
    -cumulative_logpdf(ensemble.dist, configuration.s_traj |> MergeWith(configuration.x_traj), ensemble.dtimes)
end

function sample(configuration::SRXconfiguration, system::ConditionalEnsemble; θ=0.0)
    if θ != 0.0
        error("can only use DirectMC with JumpNetwork")
    end
    cb = TrajectoryCallback(configuration.s_traj)
    cb = DiscreteCallback(cb, cb, save_positions=(false, false))
    jprob = system.jump_problem
    integrator = DiffEqBase.init(jprob, SSAStepper(), callback=cb, tstops=configuration.s_traj.t, numsteps_hint=0)
    iter = SSAIter(integrator)
    rtraj = sub_trajectory(iter, system.indep_idxs)
    SRXconfiguration(configuration.s_traj, rtraj, configuration.x_traj)
end

function collect_samples(initial::SRXconfiguration, ensemble::ConditionalEnsemble, num_samples::Int)
    cb = TrajectoryCallback(initial.s_traj)
    cb = DiscreteCallback(cb, cb, save_positions=(false, false))
    jprob = ensemble.jump_problem

    idxs = ensemble.indep_idxs[ensemble.dep_idxs]

    result = Array{Float64,2}(undef, length(ensemble.dtimes), num_samples)
    for result_col ∈ eachcol(result)
        cb.condition.index = 1
        integrator = DiffEqBase.init(jprob, SSAStepper(), callback=cb, tstops=initial.s_traj.t, numsteps_hint=0)
        iter = SSAIter(integrator) |> Map((u,t,i)::Tuple -> (u,t,0))
        cumulative_logpdf!(result_col, ensemble.dist, merge_trajectories(iter, initial.x_traj), ensemble.dtimes)
    end

    result
end

function simulate(algorithm::DirectMCEstimate, initial::Union{SXconfiguration,SRXconfiguration}, system)
    samples = collect_samples(initial, system, algorithm.num_samples)
    DirectMCResult(samples)
end

function create_integrator(conf::SRXconfiguration, ensemble::ConditionalEnsemble, u0, tspan::Tuple)
    s_traj = conf.s_traj
    cb = TrajectoryCallback(s_traj)
    cb = DiscreteCallback(cb, cb, save_positions=(false, false))
    jprob = remake(ensemble.jump_problem, u0=u0, tspan=tspan)

    i1 = clamp(searchsortedfirst(s_traj.t, tspan[1]), 1, length(s_traj.t))
    i2 = clamp(searchsortedlast(s_traj.t, tspan[2]), 1, length(s_traj.t))

    tstops = @view s_traj.t[i1:i2]
    integrator = DiffEqBase.init(jprob, SSAStepper(), callback=cb, tstops=tstops, numsteps_hint=0)
end

function propagate(conf::SRXconfiguration, ensemble::ConditionalEnsemble, u0, tspan::Tuple)
    # s_traj = get_slice(conf.s_traj, tspan)
    integrator = create_integrator(conf, ensemble, u0, tspan)
    iter = SSAIter(integrator) |> Map((u,t,i)::Tuple -> (u,t,0))
    ix1 = max(searchsortedfirst(conf.x_traj.t, tspan[1]), 1)

    log_weight = trajectory_energy(ensemble.dist, iter |> MergeWith(conf.x_traj, ix1), tspan=tspan)

    copy(integrator.u), log_weight
end

function energy_difference(configuration::SRXconfiguration, ensemble::ConditionalEnsemble)
    traj = merge_trajectories(configuration.s_traj, configuration.r_traj, configuration.x_traj)
    -cumulative_logpdf(ensemble.dist, traj, ensemble.dtimes)
end 

function marginal_configuration(conf::SRXconfiguration)
    new_s = conf.s_traj |> MergeWith(conf.r_traj) |> Map((u, t, i)::Tuple -> (SVector(u...), t, i)) |> collect_trajectory
    SXconfiguration(new_s, conf.x_traj)
end

# MCMC Moves in trajectory space

mutable struct TrajectoryChain{Ensemble} <: MarkovChain
    ensemble::Ensemble
    # interaction parameter
    θ::Float64

    # to save statistics
    last_regrowth::Float64
    accepted_list::Vector{Float64}
    rejected_list::Vector{Float64}
end

chain(ensemble; θ::Real=1.0) = TrajectoryChain(ensemble, θ, 0.0, Float64[], Float64[])

# reset statistics
function reset(pot::TrajectoryChain)
    resize!(pot.accepted_list, 0)
    resize!(pot.rejected_list, 0)
end

function accept(pot::TrajectoryChain)
    push!(pot.accepted_list, pot.last_regrowth)
end

function reject(pot::TrajectoryChain)
    push!(pot.rejected_list, pot.last_regrowth)
end

function energy(conf::SXconfiguration, chain::TrajectoryChain; θ=chain.θ) 
    if θ > zero(θ)
        -θ * trajectory_energy(chain.ensemble.dist, conf.s_traj |> MergeWith(conf.x_traj))
    else
        0.0
    end
end

function propose!(new_conf, old_conf, chain::TrajectoryChain) 
        chain.last_regrowth = propose!(new_conf, old_conf, chain.ensemble)
        new_conf
end
propose!(new_conf::SXconfiguration, old_conf::SXconfiguration, ensemble::MarginalEnsemble) = propose!(new_conf.s_traj, old_conf.s_traj, ensemble)

function propose!(new_traj::Trajectory, old_traj::Trajectory, ensemble::MarginalEnsemble)
    jump_problem = ensemble.jump_problem

    regrow_duration = rand() * duration(old_traj)

    if rand(Bool)
        shoot_forward!(new_traj, old_traj, jump_problem, old_traj.t[end] - regrow_duration)
    else
        shoot_backward!(new_traj, old_traj, jump_problem, old_traj.t[begin] + regrow_duration)
    end

    regrow_duration
end

function shoot_forward!(new_traj::Trajectory, old_traj::Trajectory, jump_problem::DiffEqBase.AbstractJumpProblem, branch_time::Real)
    branch_value = old_traj(branch_time)
    branch_point = searchsortedfirst(old_traj.t, branch_time)
    tspan = (branch_time, old_traj.t[end])

    empty!(new_traj.u)
    empty!(new_traj.t)
    empty!(new_traj.i)
    append!(new_traj.u, @view old_traj.u[begin:branch_point - 1])
    append!(new_traj.t, @view old_traj.t[begin:branch_point - 1])
    append!(new_traj.i, @view old_traj.i[begin:branch_point - 1])

    jump_problem = DiffEqBase.remake(jump_problem; u0=branch_value, tspan=tspan)
    integrator = DiffEqBase.init(jump_problem, SSAStepper())
    iter = SSAIter(integrator)
    new_branch = collect_trajectory(iter)

    append!(new_traj.t, new_branch.t)
    append!(new_traj.u, new_branch.u)
    append!(new_traj.i, new_branch.i)
    nothing
end

function shoot_backward!(new_traj::Trajectory, old_traj::Trajectory, jump_problem::DiffEqBase.AbstractJumpProblem, branch_time::Real)
    branch_value = old_traj(branch_time)
    branch_point = searchsortedfirst(old_traj.t, branch_time)
    tspan = (old_traj.t[begin], branch_time)

    jump_problem = DiffEqBase.remake(jump_problem; u0=branch_value, tspan=tspan)
    integrator = DiffEqBase.init(jump_problem, SSAStepper())
    iter = SSAIter(integrator)
    new_branch = collect_trajectory(iter)

    empty!(new_traj.u)
    empty!(new_traj.t)
    empty!(new_traj.i)

    append!(new_traj.u, @view new_branch.u[end - 1:-1:begin])
    append!(new_traj.u, @view old_traj.u[branch_point:end])
    append!(new_traj.i, @view new_branch.i[end - 1:-1:begin])
    append!(new_traj.i, @view old_traj.i[branch_point:end])

    for rtime in @view new_branch.t[end:-1:begin + 1]
        push!(new_traj.t, branch_time - rtime)
    end
    append!(new_traj.t, @view old_traj.t[branch_point:end])
    nothing
end