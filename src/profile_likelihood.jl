const dict_lock = ReentrantLock()

"""
    profile(prob::LikelihoodProblem, sol::LikelihoodSolution, n=1:number_of_parameters(prob);
        alg=get_optimiser(sol),
        conf_level::F=0.95,
        confidence_interval_method=:spline,
        threshold=get_chisq_threshold(conf_level),
        resolution=200,
        param_ranges=construct_profile_ranges(sol, get_lower_bounds(prob), get_upper_bounds(prob), resolution),
        min_steps=10,
        normalise::Bool=true,
        spline_alg=FritschCarlsonMonotonicInterpolation,
        extrap=Line,
        parallel=false,
        next_initial_estimate_method = :prev,
        kwargs...)

Computes profile likelihoods for the parameters from a likelihood problem `prob` with MLEs `sol`.

See also [`replace_profile!`](@ref) which allows you to re-profile a parameter in case you are not satisfied with 
the results. For plotting, see the `plot_profiles` function (requires that you have loaded CairoMakie.jl and 
LaTeXStrings.jl to access the function).

# Arguments 
- `prob::LikelihoodProblem`: The [`LikelihoodProblem`](@ref).
- `sol::LikelihoodSolution`: The [`LikelihoodSolution`](@ref). See also [`mle`](@ref).
- `n=1:number_of_parameters(prob)`: The parameter indices to compute the profile likelihoods for.

# Keyword Arguments 
- `alg=get_optimiser(sol)`: The optimiser to use for solving each optimisation problem. 
- `conf_level::F=0.95`: The level to use for the [`ConfidenceInterval`](@ref)s.
- `confidence_interval_method=:spline`: The method to use for computing the confidence intervals. See also [`get_confidence_intervals!`](@ref). The default `:spline` uses rootfinding on the spline through the data, defining a continuous function, while the alternative `:extrema` simply takes the extrema of the values that exceed the threshold.
- `threshold=get_chisq_threshold(conf_level)`: The threshold to use for defining the confidence intervals. 
- `resolution=200`: The number of points to use for evaluating the profile likelihood in each direction starting from the MLE (giving a total of `2resolution` points). - `resolution=200`: The number of points to use for defining `grids` below, giving the number of points to the left and right of each interest parameter. This can also be a vector, e.g. `resolution = [20, 50, 60]` will use `20` points for the first parameter, `50` for the second, and `60` for the third. 
- `param_ranges=construct_profile_ranges(sol, get_lower_bounds(prob), get_upper_bounds(prob), resolution)`: The ranges to use for each parameter.
- `min_steps=10`: The minimum number of steps to allow for the profile in each direction. If fewer than this number of steps are used before reaching the threshold, then the algorithm restarts and computes the profile likelihood a number `min_steps` of points in that direction. See also `min_steps_fallback`.
- `min_steps_fallback=:replace`: Method to use for updating the profile when it does not reach the minimum number of steps, `min_steps`. See also [`reach_min_steps!`](@ref). If `:replace`, then the profile is completely replaced and we use `min_steps` equally spaced points to replace it. If `:refine`, we just fill in some of the space in the grid so that a `min_steps` number of points are reached. Note that this latter option will mean that the spacing is no longer constant between parameter values. You can use `:refine_parallel` to apply `:refine` in parallel.
- `normalise::Bool=true`: Whether to optimise the normalised profile log-likelihood or not. 
- `spline_alg=FritschCarlsonMonotonicInterpolation`: The interpolation algorithm to use for computing a spline from the profile data. See Interpolations.jl. 
- `extrap=Line`: The extrapolation algorithm to use for computing a spline from the profile data. See Interpolations.jl.
- `parallel=false`: Whether to use multithreading. If `true`, will use multithreading so that multiple parameters are profiled at once, and the steps to the left and right are done at the same time. 
- `next_initial_estimate_method = :prev`: Method for selecting the next initial estimate when stepping forward when profiling. `:prev` simply uses the previous solution, but you can also use `:interp` to use linear interpolation. See also [`set_next_initial_estimate!`](@ref).
- `kwargs...`: Extra keyword arguments to pass into `solve` for solving the `OptimizationProblem`. See also the docs from Optimization.jl.

# Output 
Returns a [`ProfileLikelihoodSolution`](@ref).
"""
function profile(prob::LikelihoodProblem, sol::LikelihoodSolution, n=1:number_of_parameters(prob);
    alg=get_optimiser(sol),
    conf_level::F=0.95,
    confidence_interval_method=:spline,
    threshold=get_chisq_threshold(conf_level),
    resolution=200,
    param_ranges=construct_profile_ranges(sol, get_lower_bounds(prob), get_upper_bounds(prob), resolution),
    min_steps=10,
    min_steps_fallback=:replace,
    normalise::Bool=true,
    spline_alg=FritschCarlsonMonotonicInterpolation,
    extrap=Line,
    parallel=false,
    next_initial_estimate_method=:prev,
    kwargs...) where {F}
    parallel = _Val(parallel)
    confidence_interval_method = _Val(confidence_interval_method)
    min_steps_fallback = _Val(min_steps_fallback)
    spline_alg = _Val(spline_alg)
    next_initial_estimate_method = _Val(next_initial_estimate_method)
    ## Extract the problem and solution 
    opt_prob, mles, ℓmax = extract_problem_and_solution(prob, sol)

    ## Prepare the profile results 
    N = length(n)
    T = number_type(mles)
    θ, prof, other_mles, splines, confidence_intervals = prepare_profile_results(N, T, F, spline_alg, extrap)

    ## Normalise the objective function 
    shifted_opt_prob = normalise_objective_function(opt_prob, ℓmax, normalise)

    ## Loop over each parameter 
    num_params = number_of_parameters(shifted_opt_prob)
    if parallel == Val(false)
        for _n in n
            profile_single_parameter!(θ, prof, other_mles, splines, confidence_intervals,
                _n, num_params, param_ranges, mles,
                shifted_opt_prob, alg, ℓmax, normalise, threshold, min_steps,
                spline_alg, extrap, confidence_interval_method, conf_level; next_initial_estimate_method, min_steps_fallback, parallel, kwargs...)
        end
    else
        Base.Threads.@threads for _n in n
           profile_single_parameter!(θ, prof, other_mles, splines, confidence_intervals,
                _n, num_params, param_ranges, deepcopy(mles),
                deepcopy(shifted_opt_prob), alg, deepcopy(ℓmax), normalise, threshold, min_steps,
                spline_alg, extrap, confidence_interval_method, conf_level; next_initial_estimate_method, min_steps_fallback, parallel, kwargs...)
        end
    end
    return ProfileLikelihoodSolution(θ, prof, prob, sol, splines, confidence_intervals, other_mles)
end

"""
    replace_profile!(prof::ProfileLikelihoodSolution, n);
        alg=get_optimiser(prof.likelihood_solution),
        conf_level::F=0.95,
        confidence_interval_method=:spline,
        threshold=get_chisq_threshold(conf_level),
        resolution=200,
        param_ranges=construct_profile_ranges(prof.likelihood_solution, get_lower_bounds(prof.likelihood_problem), get_upper_bounds(prof.likelihood_problem), resolution),
        min_steps=10,
        min_steps_fallback=:replace,
        normalise::Bool=true,
        spline_alg=FritschCarlsonMonotonicInterpolation,
        extrap=Line,
        parallel=false,
        next_initial_estimate_method=:prev,
        kwargs...) where {F}

Given an existing `prof::ProfileLikelihoodSolution`, replaces the profile results for the parameters in `n` by re-profiling. The keyword 
arguments are the same as for [`profile`](@ref).
"""
function replace_profile!(prof::ProfileLikelihoodSolution, n;
    alg=get_optimiser(prof.likelihood_solution),
    conf_level::F=0.95,
    confidence_interval_method=:spline,
    threshold=get_chisq_threshold(conf_level),
    resolution=200,
    param_ranges=construct_profile_ranges(prof.likelihood_solution, get_lower_bounds(prof.likelihood_problem), get_upper_bounds(prof.likelihood_problem), resolution),
    min_steps=10,
    min_steps_fallback=:replace,
    normalise::Bool=true,
    spline_alg=FritschCarlsonMonotonicInterpolation,
    extrap=Line,
    parallel=false,
    next_initial_estimate_method=:prev,
    kwargs...) where {F}
    _prof = profile(prof.likelihood_problem, prof.likelihood_solution, n;
        alg, conf_level, confidence_interval_method,
        threshold, resolution, param_ranges,
        min_steps, min_steps_fallback, normalise, spline_alg, extrap,
        parallel, next_initial_estimate_method, kwargs...)
    for _n in n
        prof.parameter_values[_n] = _prof.parameter_values[_n]
        prof.profile_values[_n] = _prof.profile_values[_n]
        prof.splines[_n] = _prof.splines[_n]
        prof.confidence_intervals[_n] = _prof.confidence_intervals[_n]
        prof.other_mles[_n] = _prof.other_mles[_n]
    end
    return nothing
end

"""
    refine_profile!(prof::ProfileLikelihoodSolution, n;
        alg=get_optimiser(prof.likelihood_solution),
        conf_level::F=0.95,
        confidence_interval_method=:spline,
        threshold=get_chisq_threshold(conf_level),
        target_number=10,
        normalise::Bool=true,
        spline_alg=FritschCarlsonMonotonicInterpolation,
        extrap=Line,
        parallel=false,
        kwargs...) where {F}

Given an existing `prof::ProfileLikelihoodSolution`, refines the profile results for the parameters in `n` by adding more points. The keyword 
arguments are the same as for [`profile`](@ref). `target_number` is the total number of points that should be included in the end (not how many more 
are added).
"""
function refine_profile!(prof::ProfileLikelihoodSolution, n;
    alg=get_optimiser(prof.likelihood_solution),
    conf_level::F=0.95,
    confidence_interval_method=:spline,
    threshold=get_chisq_threshold(conf_level),
    target_number=10,
    normalise::Bool=true,
    spline_alg=FritschCarlsonMonotonicInterpolation,
    extrap=Line,
    parallel=false,
    kwargs...) where {F}
    parallel = _Val(parallel)
    confidence_interval_method = _Val(confidence_interval_method)
    spline_alg = _Val(spline_alg)
    prob = get_likelihood_problem(prof)
    sol = get_likelihood_solution(prof)
    opt_prob, mles, ℓmax = extract_problem_and_solution(prob, sol)
    shifted_opt_prob = normalise_objective_function(opt_prob, ℓmax, normalise)
    num_params = number_of_parameters(shifted_opt_prob)
    cache = DiffCache(zeros(number_type(mles), num_params))
    splines = get_splines(prof)
    confidence_intervals = get_confidence_intervals(prof)
    parameter_values = get_parameter_values(prof)
    profile_values = get_profile_values(prof)
    other_mles = get_other_mles(prof)
    for _n in n
        _refine_single_parameter!(prof, parameter_values, profile_values, other_mles, splines, confidence_intervals,
            _n, shifted_opt_prob, cache, alg, ℓmax, normalise, target_number, spline_alg, extrap,
            confidence_interval_method, threshold, mles, conf_level, parallel; kwargs...)
    end
    return nothing
end

function _refine_single_parameter!(prof::ProfileLikelihoodSolution, parameter_values, profile_values, other_mles, splines, confidence_intervals,
    _n, shifted_opt_prob, cache, alg, ℓmax, normalise, target_number, spline_alg, extrap,
    confidence_interval_method, threshold, mles, conf_level, parallel; kwargs...)
    restricted_prob = exclude_parameter(shifted_opt_prob, _n)
    _param_vals = get_parameter_values(prof[_n])
    if length(_param_vals) < target_number
        _profile_vals = get_profile_values(prof[_n])
        _other_mles = get_other_mles(prof[_n])
        if parallel == Val(false)
            _reach_min_steps_refine!(_param_vals, _profile_vals, _other_mles, restricted_prob, _n, cache, alg, ℓmax, normalise, target_number; kwargs...)
        else
            _reach_min_steps_parallel_refine!(_param_vals, _profile_vals, _other_mles, restricted_prob, _n, cache, alg, ℓmax, normalise, target_number; kwargs...)
        end
        _sort_results!(_profile_vals, _param_vals, _other_mles)
        _cleanup_duplicates!(_profile_vals, _param_vals, _other_mles)
        get_results!(parameter_values, profile_values, other_mles, splines, confidence_intervals, _n,
            _param_vals, _profile_vals, _other_mles,
            spline_alg, extrap, confidence_interval_method, threshold, mles, conf_level)
    end
    return nothing
end

@inline function exclude_parameter(shifted_opt_prob, n, sub_cache_left, sub_cache_right)
    restricted_prob_left = exclude_parameter(deepcopy(shifted_opt_prob), n)
    restricted_prob_right = exclude_parameter(deepcopy(shifted_opt_prob), n)
    restricted_prob_left.u0 .= sub_cache_left
    restricted_prob_right.u0 .= sub_cache_right
    return restricted_prob_left, restricted_prob_right
end

function get_results!(θ, prof, other_mles, splines, confidence_intervals, n,
    combined_param_vals, combined_profiles, combined_other_mles,
    spline_alg, extrap, confidence_interval_method, threshold, mles, conf_level)
    lock(dict_lock) do
        θ[n] = combined_param_vals
        prof[n] = combined_profiles
        other_mles[n] = combined_other_mles
        spline_profile!(splines, n, combined_param_vals, combined_profiles, spline_alg, extrap)
        get_confidence_intervals!(confidence_intervals, confidence_interval_method,
            n, combined_param_vals, combined_profiles, threshold, spline_alg, extrap, mles, conf_level)
    end
    return nothing
end

function profile_single_parameter!(θ, prof, other_mles, splines, confidence_intervals,
    n, num_params, param_ranges, mles,
    shifted_opt_prob, alg, ℓmax, normalise, threshold, min_steps,
    spline_alg, extrap, confidence_interval_method, conf_level; min_steps_fallback=Val(:replace), next_initial_estimate_method=Val(:prev), parallel=Val(false), kwargs...)

    _param_ranges = param_ranges[n]
    left_profile_vals, right_profile_vals,
    left_param_vals, right_param_vals,
    left_other_mles, right_other_mles,
    combined_profiles, combined_param_vals, combined_other_mles,
    cache, sub_cache = prepare_cache_vectors(n, num_params, _param_ranges, mles)
    sub_cache_left, sub_cache_right = deepcopy(sub_cache), deepcopy(sub_cache)

    restricted_prob_left, restricted_prob_right = exclude_parameter(shifted_opt_prob, n, sub_cache_left, sub_cache_right)

    find_endpoint!(left_param_vals, left_profile_vals, left_other_mles, restricted_prob_left, sub_cache_left,
        right_param_vals, right_profile_vals, right_other_mles, restricted_prob_right, sub_cache_right,
        _param_ranges, threshold, min_steps, mles, n, cache, alg, ℓmax, normalise, parallel;
        min_steps_fallback, next_initial_estimate_method, kwargs...)

    combine_and_clean_results!(left_profile_vals, right_profile_vals,
        left_param_vals, right_param_vals,
        left_other_mles, right_other_mles,
        combined_profiles, combined_param_vals, combined_other_mles)

    get_results!(θ, prof, other_mles, splines, confidence_intervals, n,
        combined_param_vals, combined_profiles, combined_other_mles,
        spline_alg, extrap, confidence_interval_method, threshold, mles, conf_level)
    return nothing
end

function construct_profile_ranges(lower_bound, upper_bound, midpoint, resolution)
    if ⊻(isinf(lower_bound), isinf(upper_bound))
        throw("The provided parameter bounds must be finite.")
    end
    left_range = LinRange(midpoint, lower_bound, resolution)
    right_range = LinRange(midpoint, upper_bound, resolution)
    param_ranges = (left_range, right_range)
    return param_ranges
end
function construct_profile_ranges(sol::LikelihoodSolution{N,Θ,P,M,R,A}, lower_bounds, upper_bounds, resolutions) where {N,Θ,P,M,R,A}
    param_ranges = Vector{NTuple{2,LinRange{Float64,Int}}}(undef, number_of_parameters(sol))
    mles = get_mle(sol)
    for i in 1:N
        param_ranges[i] = construct_profile_ranges(lower_bounds[i], upper_bounds[i], mles[i], resolutions isa Number ? resolutions : resolutions[i])
    end
    return param_ranges
end

function extract_problem_and_solution(prob::LikelihoodProblem, sol::LikelihoodSolution)
    opt_prob = get_problem(prob)
    mles = deepcopy(get_mle(sol))
    ℓmax = get_maximum(sol)
    return opt_prob, mles, ℓmax
end

function prepare_profile_results(N, T, F, spline_alg=FritschCarlsonMonotonicInterpolation, extrap=Line)
    θ = Dict{Int,Vector{T}}([])
    prof = Dict{Int,Vector{T}}([])
    other_mles = Dict{Int,Vector{Vector{T}}}([])
    spline_alg = take_val(spline_alg)
    if typeof(spline_alg) <: Gridded
        spline_type = typeof(extrapolate(interpolate((T.(collect(1:20)),), T.(collect(1:20)), spline_alg isa Type ? spline_alg() : spline_alg), extrap isa Type ? extrap() : extrap))
    else
        spline_type = typeof(extrapolate(interpolate(T.(collect(1:20)), T.(collect(1:20)), spline_alg isa Type ? spline_alg() : spline_alg), extrap isa Type ? extrap() : extrap))
    end
    splines = Dict{Int,spline_type}([])
    confidence_intervals = Dict{Int,ConfidenceInterval{T,F}}([])
    sizehint!(θ, N)
    sizehint!(prof, N)
    sizehint!(other_mles, N)
    sizehint!(splines, N)
    sizehint!(confidence_intervals, N)
    return θ, prof, other_mles, splines, confidence_intervals
end

@inline function normalise_objective_function(opt_prob, ℓmax::T, normalise) where {T}
    normalise = take_val(normalise)
    shift = normalise ? -ℓmax : zero(T)
    shifted_opt_prob = shift_objective_function(opt_prob, shift)
    return shifted_opt_prob
end

function reset_profile_vectors!(restricted_prob, param_vals, profile_vals, other_mles, min_steps, mles, n)
    restricted_prob.u0 .= mles[Not(n)]
    new_range = LinRange(param_vals[1], param_vals[end], min_steps)
    !isempty(param_vals) && empty!(param_vals)
    !isempty(profile_vals) && empty!(profile_vals)
    !isempty(other_mles) && empty!(other_mles)
    return new_range
end

"""
    set_next_initial_estimate!(sub_cache, param_vals, other_mles, prob, θₙ; next_initial_estimate_method=Val(:prev))

Method for selecting the next initial estimate for the optimisers. `sub_cache` is the cache vector for placing 
the initial estimate into, `param_vals` is the current list of parameter values for the interest parameter, 
and `other_mles` is the corresponding list of previous optimisers. `prob` is the `OptimizationProblem`. The value 
`θₙ` is the next value of the interest parameter.

The available methods are: 

- `next_initial_estimate_method = Val(:prev)`: If this is selected, simply use `other_mles[end]`, i.e. the previous optimiser. 
- `next_initial_estimate_method = Val(:interp)`: If this is selected, the next optimiser is determined via linear interpolation using the data `(param_vals[end-1], other_mles[end-1]), (param_vals[end], other_mles[end])`. If the new approximation is outside of the parameter bounds, falls back to `next_initial_estimate_method = :prev`.
"""
function set_next_initial_estimate!(sub_cache, param_vals, other_mles, prob, θₙ; next_initial_estimate_method=Val(:prev))
    if next_initial_estimate_method == Val(:prev)
        _set_next_initial_estimate_mle!(sub_cache, other_mles)
    elseif next_initial_estimate_method == Val(:interp)
        _set_next_initial_estimate_interp!(sub_cache, param_vals, other_mles, prob, θₙ)
    else
        throw("Invalid initial estimate method provided, $next_initial_estimate_method. The available options are :prev and :interp.")
    end
    return nothing
end

function _set_next_initial_estimate_mle!(sub_cache, other_mles::AbstractVector)
    sub_cache .= other_mles[end]
    return nothing
end

function _set_next_initial_estimate_interp!(sub_cache, param_vals, other_mles, prob, θₙ)
    if length(other_mles) == 1
        _set_next_initial_estimate_mle!(sub_cache, other_mles)
    else
        linear_extrapolation!(sub_cache, θₙ, param_vals[end-1], other_mles[end-1], param_vals[end], other_mles[end])
        if !parameter_is_inbounds(prob, sub_cache)
            _set_next_initial_estimate_mle!(sub_cache, other_mles)
        end
    end
    return nothing
end

function find_endpoint!(left_param_vals, left_profile_vals, left_other_mles, restricted_prob_left, sub_cache_left,
    right_param_vals, right_profile_vals, right_other_mles, restricted_prob_right, sub_cache_right,
    param_ranges, threshold, min_steps, mles, n, cache, alg, ℓmax, normalise, parallel;
    min_steps_fallback=Val(:replace), next_initial_estimate_method=Val(:interp), kwargs...)
    if parallel == Val(false)
        _find_endpoint_serial!(left_param_vals, left_profile_vals, left_other_mles, restricted_prob_left, sub_cache_left,
            right_param_vals, right_profile_vals, right_other_mles, restricted_prob_right, sub_cache_right,
            param_ranges, threshold, min_steps, mles, n, cache, alg, ℓmax, normalise;
            min_steps_fallback, next_initial_estimate_method, kwargs...)
    else
        _find_endpoint_parallel!(left_param_vals, left_profile_vals, left_other_mles, restricted_prob_left, sub_cache_left,
            right_param_vals, right_profile_vals, right_other_mles, restricted_prob_right, sub_cache_right,
            param_ranges, threshold, min_steps, mles, n, cache, alg, ℓmax, normalise;
            min_steps_fallback, next_initial_estimate_method, kwargs...)
    end
    return nothing
end

function _find_endpoint_serial!(left_param_vals, left_profile_vals, left_other_mles, restricted_prob_left, sub_cache_left,
    right_param_vals, right_profile_vals, right_other_mles, restricted_prob_right, sub_cache_right,
    param_ranges, threshold, min_steps, mles, n, cache, alg, ℓmax, normalise;
    min_steps_fallback=Val(:replace), next_initial_estimate_method=Val(:interp), kwargs...)
    find_endpoint!(left_param_vals, left_profile_vals, left_other_mles, param_ranges[1],
        restricted_prob_left, n, cache, alg, sub_cache_left, ℓmax, normalise,
        threshold, min_steps, mles; min_steps_fallback, next_initial_estimate_method, kwargs...) # left
    find_endpoint!(right_param_vals, right_profile_vals, right_other_mles, param_ranges[2],
        restricted_prob_right, n, cache, alg, sub_cache_right, ℓmax, normalise,
        threshold, min_steps, mles; min_steps_fallback, next_initial_estimate_method, kwargs...) # right
    return nothing
end

function _find_endpoint_parallel!(left_param_vals, left_profile_vals, left_other_mles, restricted_prob_left, sub_cache_left,
    right_param_vals, right_profile_vals, right_other_mles, restricted_prob_right, sub_cache_right,
    param_ranges, threshold, min_steps, mles, n, cache, alg, ℓmax, normalise;
    min_steps_fallback=Val(:replace), next_initial_estimate_method=Val(:interp), kwargs...)
    @sync begin
        @async find_endpoint!(left_param_vals, left_profile_vals, left_other_mles, param_ranges[1],
            restricted_prob_left, n, cache, alg, sub_cache_left, ℓmax, normalise,
            threshold, min_steps, mles; min_steps_fallback, next_initial_estimate_method, kwargs...) # left
        @async find_endpoint!(right_param_vals, right_profile_vals, right_other_mles, param_ranges[2],
            restricted_prob_right, n, cache, alg, sub_cache_right, ℓmax, normalise,
            threshold, min_steps, mles; min_steps_fallback, next_initial_estimate_method, kwargs...) # right
    end
    return nothing
end

function find_endpoint!(param_vals, profile_vals, other_mles, param_range,
    restricted_prob, n, cache, alg, sub_cache, ℓmax, normalise,
    threshold, min_steps, mles; min_steps_fallback, next_initial_estimate_method, kwargs...)
    steps = 1
    for θₙ in param_range
        add_point!(param_vals, profile_vals, other_mles, θₙ, param_range,
            restricted_prob, n, cache, alg, sub_cache, ℓmax, normalise,
            threshold, min_steps, mles; next_initial_estimate_method, kwargs...)
        steps += 1
        profile_vals[end] ≤ threshold && break
    end
    ## Check if we need to extend the values 
    if steps < min_steps
        reach_min_steps!(param_vals, profile_vals, other_mles, param_range,
            restricted_prob, n, cache, alg, sub_cache, ℓmax, normalise,
            threshold, min_steps, mles; min_steps_fallback, next_initial_estimate_method, kwargs...)
    end
    return nothing
end

function add_point!(param_vals, profile_vals, other_mles, θₙ, param_range,
    restricted_prob, n, cache, alg, sub_cache, ℓmax, normalise,
    threshold, min_steps, mles; next_initial_estimate_method, kwargs...)
    !isempty(other_mles) && set_next_initial_estimate!(sub_cache, param_vals, other_mles, restricted_prob, θₙ; next_initial_estimate_method)
    push!(param_vals, θₙ)
    ## Fix the objective function 
    fixed_prob = construct_fixed_optimisation_function(restricted_prob, n, θₙ, cache)
    fixed_prob.u0 .= sub_cache
    ## Solve the fixed problem 
    soln = solve(fixed_prob, alg; kwargs...)
    push!(profile_vals, -soln.objective - ℓmax * !normalise)
    push!(other_mles, soln.u)
    return nothing
end

"""
    reach_min_steps!(param_vals, profile_vals, other_mles, param_range,
        restricted_prob, n, cache, alg, sub_cache, ℓmax, normalise,
        threshold, min_steps, mles; min_steps_fallback=Val(:replace), next_initial_estimate_method=Val(:interp), kwargs...)

Updates the results from the side of a profile likelihood (e.g. left or right side, see `find_endpoint!`) to meet the minimum number of 
steps `min_steps`.

# Arguments 
- `param_vals`: The parameter values. 
- `profile_vals`: The profile values. 
- `other_mles`: The other MLEs, i.e. the optimised parameters for the corresponding fixed parameter values in `param_vals`.
- `param_range`: The vector of parameter values.
- `restricted_prob`: The optimisation problem, restricted to the `n`th parameter. 
- `n`: The parameter being profiled.
- `cache`: A cache for the complete parameter vector. 
- `alg`: The algorithm used for optimising. 
- `sub_cache`: A cache for the parameter vector excluding the `n`th parameter.
- `ℓmax`: The maximum likelihood. 
- `normalise`: Whether the optimisation problem is normalised.
- `threshold`: The threshold for the confidence interval. 
- `min_steps`: The minimum number of steps to reach. 
- `mles`: The MLEs.

# Keyword Arguments 
- `min_steps_fallback=Val(:interp)`: The method used for reaching the minimum number of steps. The available methods are:

    - `min_steps_fallback = Val(:replace)`: This method completely replaces the profile, defining a grid from the MLE to the computed endpoint with `min_steps` points. No information is re-used.
    - `min_steps_fallback = Val(:refine)`: This method just adds more points to the profile, filling in enough points so that the total number of points is `min_steps`. The initial estimates in this case come from a spline from `other_mles`.
    - `min_steps_fallback = Val(:parallel_refine)`: This applies the method above, except in parallel. 

- `next_initial_estimate_method=Val(:replace)`: The method used for obtaining initial estimates. See also [`set_next_initial_estimate!`](@ref).
"""
function reach_min_steps!(param_vals, profile_vals, other_mles, param_range,
    restricted_prob, n, cache, alg, sub_cache, ℓmax, normalise,
    threshold, min_steps, mles; min_steps_fallback=Val(:replace), next_initial_estimate_method=Val(:interp), kwargs...)
    if min_steps_fallback == Val(:replace)
        _reach_min_steps_replace!(param_vals, profile_vals, other_mles, param_range,
            restricted_prob, n, cache, alg, sub_cache, ℓmax, normalise,
            threshold, min_steps, mles; min_steps_fallback, next_initial_estimate_method, kwargs...)
    elseif min_steps_fallback == Val(:refine)
        _reach_min_steps_refine!(param_vals, profile_vals, other_mles, restricted_prob, n, cache, alg, ℓmax, normalise, min_steps; kwargs...)
    elseif min_steps_fallback == Val(:parallel_refine)
        _reach_min_steps_parallel_refine!(param_vals, profile_vals, other_mles, restricted_prob, n, cache, alg, ℓmax, normalise, min_steps; kwargs...)
    else
        throw("Invalid min_steps_fallback method.")
    end
    return nothing
end

function _reach_min_steps_replace!(param_vals, profile_vals, other_mles, param_range,
    restricted_prob, n, cache, alg, sub_cache, ℓmax, normalise,
    threshold, min_steps, mles; min_steps_fallback, next_initial_estimate_method, kwargs...)
    sub_cache .= mles[Not(n)]
    new_range = reset_profile_vectors!(restricted_prob, param_vals, profile_vals, other_mles, min_steps, mles, n)
    find_endpoint!(param_vals, profile_vals, other_mles, new_range,
        restricted_prob, n, cache, alg, sub_cache, ℓmax, normalise,
        typemin(threshold), zero(min_steps), mles; min_steps_fallback, next_initial_estimate_method, kwargs...)
    return nothing
end

function repopulate_points!(grid, m) # resize grid to have m points
    n = length(grid)
    a = grid[begin]
    b = grid[end]
    step = (b - a) / (m - n + 1)
    resize!(grid, m)
    for i in 2:(m-n+1)
        grid[i+n-1] = a + (i - 1) * step
    end
    return nothing
end

function bspline_other_mles(param_vals, other_mles)
    param_range = LinRange(param_vals[begin], param_vals[end], length(param_vals))
    hcat_other_mles = reduce(hcat, other_mles)
    if param_vals[begin] ≤ param_vals[end]
        itp = [scale(interpolate(mles, BSpline(Cubic(Line(OnGrid())))), param_range) for mles in eachrow(hcat_other_mles)]
        return VecBSpline(itp)
    else
        itp = [scale(interpolate(reverse(mles), BSpline(Cubic(Line(OnGrid())))), reverse(param_range)) for mles in eachrow(hcat_other_mles)]
        return VecBSpline(itp)
    end
end

function resize_profile_data!(param_vals, profile_vals, other_mles, m)
    n = length(param_vals)
    spline = bspline_other_mles(param_vals, other_mles)
    repopulate_points!(param_vals, m)
    resize!(profile_vals, m)
    resize!(other_mles, m)
    for i in (n+1):m
        other_mles[i] = spline(param_vals[i])
    end
    return nothing
end

function add_point!(profile_vals, other_mles, restricted_prob, n, i, original_length, θₙ, cache, alg, ℓmax, normalise; kwargs...)
    j = original_length + i
    fixed_prob = construct_fixed_optimisation_function(restricted_prob, n, θₙ, cache)
    fixed_prob.u0 .= other_mles[j]
    soln = solve(fixed_prob, alg; kwargs...)
    profile_vals[j] = -soln.objective - ℓmax * !normalise
    other_mles[j] .= soln.u
end

function _reach_min_steps_refine!(param_vals, profile_vals, other_mles, restricted_prob, n, cache, alg, ℓmax, normalise, min_steps; kwargs...)
    original_length = length(param_vals)
    resize_profile_data!(param_vals, profile_vals, other_mles, min_steps)
    for (i, θₙ) in enumerate(@view param_vals[original_length+1:end])
        add_point!(profile_vals, other_mles, restricted_prob, n, i, original_length, θₙ, cache, alg, ℓmax, normalise; kwargs...)
    end
    return nothing
end

function _reach_min_steps_parallel_refine!(param_vals, profile_vals, other_mles, restricted_prob, n, cache, alg, ℓmax, normalise, min_steps; kwargs...)
    original_length = length(param_vals)
    resize_profile_data!(param_vals, profile_vals, other_mles, min_steps)
    nt = Base.Threads.nthreads()
    _restricted_prob = [deepcopy(restricted_prob) for _ in 1:nt]
    _cache = [deepcopy(cache) for _ in 1:nt]
    chunked_step_itr = chunks(1:(min_steps-original_length), Base.Threads.nthreads())
    Base.Threads.@threads for (chunk_range, id) in chunked_step_itr
        for i in chunk_range
            j = original_length + i
            θₙ = param_vals[j]
            add_point!(profile_vals, other_mles, _restricted_prob[id], n, i, original_length, θₙ, _cache[id], alg, ℓmax, normalise; kwargs...)
        end
    end
    return nothing
end

function prepare_cache_vectors(n, num_params, param_ranges, mles::AbstractVector{T}) where {T}
    left_profile_vals = Vector{T}([])
    right_profile_vals = Vector{T}([])
    left_param_vals = Vector{T}([])
    right_param_vals = Vector{T}([])
    left_other_mles = Vector{Vector{T}}([])
    right_other_mles = Vector{Vector{T}}([])
    combined_profiles = Vector{T}([])
    combined_param_vals = Vector{T}([])
    combined_other_mles = Vector{Vector{T}}([])
    sizehint!(left_profile_vals, length(param_ranges[1]))
    sizehint!(right_profile_vals, length(param_ranges[2]))
    sizehint!(combined_profiles, length(param_ranges[1]) + length(param_ranges[2]))
    sizehint!(combined_param_vals, length(param_ranges[1]) + length(param_ranges[2]))
    sizehint!(combined_other_mles, length(param_ranges[1]) + length(param_ranges[2]))
    cache = DiffCache(zeros(T, num_params))
    sub_cache = zeros(T, num_params - 1)
    sub_cache .= mles[Not(n)]
    return left_profile_vals, right_profile_vals,
    left_param_vals, right_param_vals,
    left_other_mles, right_other_mles,
    combined_profiles, combined_param_vals, combined_other_mles,
    cache, sub_cache
end

function _combine_results!(left_profile_vals, right_profile_vals,
    left_param_vals, right_param_vals,
    left_other_mles, right_other_mles,
    combined_profiles, combined_param_vals, combined_other_mles)
    append!(combined_profiles, left_profile_vals, right_profile_vals)
    append!(combined_param_vals, left_param_vals, right_param_vals)
    append!(combined_other_mles, left_other_mles, right_other_mles)
    return nothing
end

function _sort_results!(profiles, param_vals, other_mles)
    sort_idx = sortperm(param_vals)
    permute!(param_vals, sort_idx)
    permute!(profiles, sort_idx)
    permute!(other_mles, sort_idx)
    return nothing
end

function _cleanup_duplicates!(profiles, param_vals, other_mles)
    idx = unique(i -> param_vals[i], eachindex(param_vals))
    keepat!(param_vals, idx)
    keepat!(profiles, idx)
    keepat!(other_mles, idx)
    return nothing
end

function combine_and_clean_results!(left_profile_vals, right_profile_vals,
    left_param_vals, right_param_vals,
    left_other_mles, right_other_mles,
    combined_profiles, combined_param_vals, combined_other_mles)
    _combine_results!(left_profile_vals, right_profile_vals,
        left_param_vals, right_param_vals,
        left_other_mles, right_other_mles,
        combined_profiles, combined_param_vals, combined_other_mles)
    _sort_results!(combined_profiles, combined_param_vals, combined_other_mles)
    _cleanup_duplicates!(combined_profiles, combined_param_vals, combined_other_mles)
    return nothing
end

function spline_profile!(splines, n, param_vals, profiles, spline_alg, extrap)
    spline_alg = take_val(spline_alg)
    try
        if typeof(spline_alg) <: Gridded
            itp = interpolate((param_vals,), profiles, spline_alg isa Type ? spline_alg() : spline_alg)
            splines[n] = extrapolate(itp, extrap isa Type ? extrap() : extrap)
        else
            itp = interpolate(param_vals, profiles, spline_alg isa Type ? spline_alg() : spline_alg)
            splines[n] = extrapolate(itp, extrap isa Type ? extrap() : extrap)
        end
    catch e
        @show e
        error("Error creating the spline. Try increasing the grid resolution for parameter $n or increasing min_steps.")
    end
    return nothing
end

"""
    get_confidence_intervals!(confidence_intervals, method, n, param_vals, profile_vals, threshold, spline_alg, extrap, mles, conf_level)

Method for computing the confidence intervals.

# Arguments
- `confidence_intervals`: The dictionary storing the confidence intervals. 
- `method`: The method to use for computing the confidence interval. The available methods are:

    - `method = Val(:spline)`: Fits a spline to `(param_vals, profile_vals)` and finds where the continuous spline equals `threshold`.
    - `method = Val(:extrema)`: Takes the first and last values in `param_vals` whose corresponding value in `profile_vals` exceeds `threshold`.

- `n`: The parameter being profiled. 
- `param_vals`: The parameter values. 
- `profile_vals`: The profile values. 
- `threshold`: The threshold for the confidence interval. 
- `spline_alg`: The algorithm to use for fitting a spline. 
- `extrap`: The extrapolation algorithm used for the spline.
- `mles`: The MLEs. 
- `conf_level`: The confidence level for the confidence interval.

# Outputs 
There are no outputs - `confidence_intervals[n]` gets the [`ConfidenceInterval`](@ref) put into it.
"""
function get_confidence_intervals!(confidence_intervals, method, n, param_vals, profile_vals, threshold, spline_alg, extrap, mles, conf_level)
    if method == Val(:spline)
        try
            _get_confidence_intervals_spline!(confidence_intervals, n, param_vals, profile_vals, threshold, spline_alg, extrap, mles, conf_level)
        catch
            @warn("Failed to create the confidence interval for parameter $n using a spline. Restarting using the extrema method.")
            get_confidence_intervals!(confidence_intervals, Val(:extrema), n, param_vals, profile_vals, threshold, spline_alg, extrap, mles, conf_level)
        end
    elseif method == Val(:extrema)
        try
            _get_confidence_intervals_extrema!(confidence_intervals, n, param_vals, profile_vals, threshold, conf_level)
        catch
            @warn("Failed to create the confidence interval for parameter $n.")
            confidence_intervals[n] = ConfidenceInterval(NaN, NaN, conf_level)
        end
    else
        throw("Invalid confidence region method selected.")
    end
    return nothing
end
function _get_confidence_intervals_spline!(confidence_intervals, n, param_vals, combined_profiles, threshold, spline_alg, extrap, mles, conf_level)
    spline_alg = take_val(spline_alg)
    itp = interpolate(param_vals, combined_profiles .- threshold, spline_alg isa Type ? spline_alg() : spline_alg)
    itp_f = (θ, _) -> itp(θ)
    left_bracket = (param_vals[begin], mles[n])
    right_bracket = (mles[n], param_vals[end])
    left_prob = IntervalNonlinearProblem(itp_f, left_bracket)
    right_prob = IntervalNonlinearProblem(itp_f, right_bracket)
    ℓ = solve(left_prob, Falsi()).u
    u = solve(right_prob, Falsi()).u
    confidence_intervals[n] = ConfidenceInterval(ℓ, u, conf_level)
    return nothing
end
function _get_confidence_intervals_extrema!(confidence_intervals, n, param_vals, profile_vals, threshold, conf_level)
    conf_region = profile_vals .≥ threshold
    idx = findall(conf_region)
    ab = extrema(param_vals[idx])
    try
        confidence_intervals[n] = ConfidenceInterval(ab..., conf_level)
    catch
        @warn("Failed to find a valid confidence interval for parameter $n. Returning the extrema of the parameter values.")
        confidence_intervals[n] = ConfidenceInterval(extrema(param_vals[n])..., conf_level)
    end
end
