# Example II: Logistic ordinary differential equation 

The following example comes from the first case study of [Simpson and Maclaren (2022)](https://doi.org/10.1101/2022.12.14.520367). First, load the packages we'll be using:

```julia
using Random 
using ProfileLikelihood
using Optimization 
using OrdinaryDiffEq
using CairoMakie 
using LaTeXStrings
using OptimizationNLopt
using Test
```

Let us consider the logistic ordinary differential equation (ODE). For ODEs, our treatment is as follows: Let us have some ODE $\mathrm dy/\mathrm dt = f(y, t; \boldsymbol \theta)$ for some parameters $\boldsymbol\theta$ of interest. We will suppose that we have some data $y_i^o$ at time $t_i$, $i=1,\ldots,n$, with initial condition $y_0^o$ at time $t_0=0$, which we model according to a normal distribution $y_i^o \mid \boldsymbol \theta \sim \mathcal N(y_i(\boldsymbol \theta), \sigma^2)$, $i=0,1,\ldots,n$, where $y_i$ is a solution of the ODE at time $t_i$. This defines a likelihood that we can use for estimating the parameters.

Let us now proceed with our example. We are considering $\mathrm du/\mathrm dt = \lambda u(1-u/K)$, $u(0)=u_0$, and our interest is in estimating $(\lambda, K, u_0)$, we will fix the standard deviation of the noise, $\sigma$, at $\sigma=10$. Note that the exact solution to this ODE is $u(t) = Ku_0/[(K-u_0)\mathrm{e}^{-\lambda t} + u_0]$.

## Data generation and setting up the problem

The first step is to generate the data.
```julia 
using OrdinaryDiffEq, Random
λ = 0.01
K = 100.0
u₀ = 10.0
t = 0:100:1000
σ = 10.0
@inline function ode_fnc(u, p, t)
    λ, K = p
    du = λ * u * (1 - u / K)
    return du
end
# Initial data is obtained by solving the ODE 
tspan = extrema(t)
p = (λ, K)
prob = ODEProblem(ode_fnc, u₀, tspan, p)
sol = solve(prob, Rosenbrock23(), saveat=t)
Random.seed!(2828)
uᵒ = sol.u + σ * randn(length(t))
```

Now having our data, we define the likelihood function.

```julia 
@inline function loglik_fnc2(θ, data, integrator)
    λ, K, u₀ = θ
    uᵒ, σ = data
    integrator.p[1] = λ
    integrator.p[2] = K
    reinit!(integrator, u₀)
    solve!(integrator)
    return gaussian_loglikelihood(uᵒ, integrator.sol.u, σ, length(uᵒ))
end
```

Now we can define our problem. We constrain the problem so that $0 \leq \lambda \leq 0.05$, $50 \leq K \leq 150$, and $0 \leq u_0 \leq 50$.

```julia
lb = [0.0, 50.0, 0.0] # λ, K, u₀
ub = [0.05, 150.0, 50.0]
θ₀ = [λ, K, u₀]
syms = [:λ, :K, :u₀]
prob = LikelihoodProblem(
    loglik_fnc2, θ₀, ode_fnc, u₀, maximum(t); # Note that u₀ is just a placeholder IC in this case since we are estimating it
    syms=syms,
    data=(uᵒ, σ),
    ode_parameters=[1.0, 1.0], # temp values for [λ, K]
    ode_kwargs=(verbose=false, saveat=t),
    f_kwargs=(adtype=Optimization.AutoFiniteDiff(),),
    prob_kwargs=(lb=lb, ub=ub),
    ode_alg=Rosenbrock23()
)
```

## Parameter estimation

Now we find the MLEs.

```julia
using OptimizationNLopt
sol = mle(prob, NLopt.LN_NELDERMEAD)
LikelihoodSolution. retcode: Failure
Maximum likelihood: -38.99053694428977
Maximum likelihood estimates: 3-element Vector{Float64}
     λ: 0.010438031266786045
     K: 99.59921873132551
     u₀: 8.098422110755225
```

We can now profile. 

```julia
prof = profile(prob, sol; alg=NLopt.LN_NELDERMEAD, parallel=false)
ProfileLikelihoodSolution. MLE retcode: Failure
Confidence intervals: 
     95.0% CI for λ: (0.006400992274213644, 0.01786032876226762)
     95.0% CI for K: (90.81154862835605, 109.54214763511888)
     95.0% CI for u₀: (1.5919805025139593, 19.070831536649305)
```

```julia
@test λ ∈ get_confidence_intervals(prof, :λ)
@test K ∈ prof.confidence_intervals[2]
@test u₀ ∈ get_confidence_intervals(prof, 3)
```

We can visualise as we did before:

```julia
using CairoMakie, LaTeXStrings
fig = plot_profiles(prof;
    latex_names=[L"\lambda", L"K", L"u_0"],
    show_mles=true,
    shade_ci=true,
    nrow=1,
    ncol=3,
    true_vals=[λ, K, u₀],
    fig_kwargs=(fontsize=30, resolution=(2109.644f0, 444.242f0)),
    axis_kwargs=(width=600, height=300))
```

![Logistic profiles](https://github.com/DanielVandH/ProfileLikelihood.jl/blob/main/test/figures/logistic_example.png?raw=true)

## Prediction intervals 

Let us now use these results to compute prediction intervals for $u(t)$. Following [Simpson and Maclaren (2022)](https://doi.org/10.1101/2022.12.14.520367), the idea is to use the profile likelihood to construct another profile likelihood, called the *profile-wise profile likelihood*, that allows us to obtain prediction intervals for some prediction function $q(\boldsymbol \theta)$. More detail is given in the mathematical details section.

The first step is to define a function $q(\boldsymbol\theta)$ that comptues our prediction given some parameters $\boldsymbol\theta$. The function in this case is simply:

```julia
function prediction_function(θ, data)
    λ, K, u₀ = θ
    t = data
    prob = ODEProblem(ode_fnc, u₀, extrema(t), (λ, K))
    sol = solve(prob, Rosenbrock23(), saveat=t)
    return sol.u
end
```

Note that the second argument `data` allows for extra parameters to be passed. To now obtain prediction intervals for `sol.u`, for each `t`, we define a large grid for `t` and use `get_prediction_intervals`:

```julia
t_many_pts = LinRange(extrema(t)..., 1000)
parameter_wise, union_intervals, all_curves, param_range =
    get_prediction_intervals(prediction_function, prof,
        t_many_pts; parallel=true)
# t_many_pts is the `data` argument, it doesn't have to be time for other problems
```

This function `get_prediction_intervals` has four outputs:

- `parameter_wise`: These are prediction intervals for the prediction at each point $t$, coming from the profile likelihood of each respective parameter:

```julia 
julia> parameter_wise
Dict{Int64, Vector{ConfidenceInterval{Float64, Float64}}} with 3 entries:
  2 => [ConfidenceInterval{Float64, Float64}(6.45444, 12.0694, 0.95), ConfidenceInterval{Float64, Float64}(6.52931, 12.1545, 0.95), ConfidenceInterval{Float64, Float64}(6.60498, 12.24, 0.95), ConfidenceInterva…  3 => [ConfidenceInterval{Float64, Float64}(1.59389, 19.0709, 0.95), ConfidenceInterval{Float64, Float64}(1.621, 19.1773, 0.95), ConfidenceInterval{Float64, Float64}(1.64856, 19.2842, 0.95), ConfidenceInterva…  1 => [ConfidenceInterval{Float64, Float64}(1.86302, 17.5828, 0.95), ConfidenceInterval{Float64, Float64}(1.89596, 17.6768, 0.95), ConfidenceInterval{Float64, Float64}(1.92948, 17.7712, 0.95), ConfidenceInter…
``` 

For example, `parameter_wise[1]` comes from varying $\lambda$, with the parameters $K$ and $u_0$ coming from optimising the likelihood function with $\lambda$ fixed.

- `union_intervals`: These are prediction intervals at each point $t$ coming from taking the union of the intervals from the corresponding elements of `parameter_wise`.

- `all_curves`: The intervals come from taking extrema over many curves. This is a `Dict` mapping parameter indices to the curves that were used, with `all_curves[i][j]` being the set of curves for the `i`th parameter (e.g. `i=1` is for $\lambda$) and the `j`th parameter.

- `param_range`: The curves come from evaluating the prediction function between the bounds of the confidence intervals for each parameter, and this output gives the parameters used, so that e.g. `all_curves[i][j]` uses `param_range[i][j]` for the value of the `i`th parameter.

Let us now use these outputs to visualise the prediction intervals. First, let us extract the solution with the true parameter values and with the MLEs.

```julia 
exact_soln = prediction_function([λ, K, u₀], t_many_pts)
mle_soln = prediction_function(get_mle(sol), t_many_pts)
```

Now let us plot the prediction intervals coming from each parameter, and from the union of all intervals (not shown yet, see below).

```julia
fig = Figure(fontsize=38, resolution=(1402.7681f0, 848.64404f0))
alp = join('a':'z')
latex_names = [L"\lambda", L"K", L"u_0"]
for i in 1:3
    ax = Axis(fig[i < 3 ? 1 : 2, i < 3 ? i : 1], title=L"(%$(alp[i])): Profile-wise PI for %$(latex_names[i])",
        titlealign=:left, width=600, height=300)
    [lines!(ax, t_many_pts, all_curves[i][:, j], color=:grey) for j in eachindex(param_range[1])]
    lines!(ax, t_many_pts, exact_soln, color=:red)
    lines!(ax, t_many_pts, mle_soln, color=:blue, linestyle=:dash)
    lines!(ax, t_many_pts, getindex.(parameter_wise[i], 1), color=:black, linewidth=3)
    lines!(ax, t_many_pts, getindex.(parameter_wise[i], 2), color=:black, linewidth=3)
end
ax = Axis(fig[2, 2], title=L"(d):$ $ Union of all intervals",
    titlealign=:left, width=600, height=300)
band!(ax, t_many_pts, getindex.(union_intervals, 1), getindex.(union_intervals, 2), color=:grey)
lines!(ax, t_many_pts, getindex.(union_intervals, 1), color=:black, linewidth=3)
lines!(ax, t_many_pts, getindex.(union_intervals, 2), color=:black, linewidth=3)
lines!(ax, t_many_pts, exact_soln, color=:red)
lines!(ax, t_many_pts, mle_soln, color=:blue, linestyle=:dash)
```

To now assess the coverage of these intervals, we want to compare them to the interval coming from the full likelihood. We find this interval by taking a large number of parameters, and finding all of them for which the normalised log-likelihood exceeds the threshold $-1.92$. We then take the parameters that give a value exceeding this threshold, compute the prediction function at these values, and then take the extrema. The code below uses the function `grid_search` that evaluates the function at many points, and we describe this function in more detail in the next example.

```julia
lb = get_lower_bounds(prob)
ub = get_upper_bounds(prob)
N = 1e5
grid = [[lb[i] + (ub[i] - lb[i]) * rand() for _ in 1:N] for i in 1:3]
grid = permutedims(reduce(hcat, grid), (2, 1))
ig = IrregularGrid(lb, ub, grid)
gs, lik_vals = grid_search(prob, ig; parallel=Val(true), save_vals=Val(true))
lik_vals .-= get_maximum(sol) # normalised 
feasible_idx = findall(lik_vals .> ProfileLikelihood.get_chisq_threshold(0.95)) # values in the confidence region 
parameter_evals = grid[:, feasible_idx]
q = [prediction_function(θ, t_many_pts) for θ in eachcol(parameter_evals)]
q_mat = reduce(hcat, q)
q_lwr = minimum(q_mat; dims=2) |> vec
q_upr = maximum(q_mat; dims=2) |> vec
lines!(ax, t_many_pts, q_lwr, color=:magenta, linewidth=3)
lines!(ax, t_many_pts, q_upr, color=:magenta, linewidth=3)
```

![Logistic prediction intervals](https://github.com/DanielVandH/ProfileLikelihood.jl/blob/main/test/figures/logistic_example_prediction.png?raw=true)

The first plot shows that the profile-wise prediction interval for $\lambda$ is quite large when $t$ is small, and then small for large time. This makes sense since the large time solution is independent of $\lambda$ (the large time solution is $u_s(t)=K$). For $K$, we see that the profile-wise interval only becomes large for large time, which again makes sense. For $u_0$ we see similar behaviour as for $\lambda$. Finally, taking the union over all the intervals, as is done in (d), shows that we fully enclose the solution coming from the MLE, as well as the true curve. The magenta curve shows the results from the full likelihood function, and is reasonably close to the approximate interval obtained from the union.

## Just the code

Here is all the code used for obtaining the results in this example, should you want a version that you can directly copy and paste.

```julia 
## Step 1: Generate the data and define the likelihood
using OrdinaryDiffEq, Random
λ = 0.01
K = 100.0
u₀ = 10.0
t = 0:100:1000
σ = 10.0
@inline function ode_fnc(u, p, t)
    λ, K = p
    du = λ * u * (1 - u / K)
    return du
end
# Initial data is obtained by solving the ODE 
tspan = extrema(t)
p = (λ, K)
prob = ODEProblem(ode_fnc, u₀, tspan, p)
sol = solve(prob, Rosenbrock23(), saveat=t)
Random.seed!(2828)
uᵒ = sol.u + σ * randn(length(t))
@inline function loglik_fnc2(θ, data, integrator)
    λ, K, u₀ = θ
    uᵒ, σ = data
    integrator.p[1] = λ
    integrator.p[2] = K
    reinit!(integrator, u₀)
    solve!(integrator)
    return gaussian_loglikelihood(uᵒ, integrator.sol.u, σ, length(uᵒ))
end

## Step 2: Define the problem 
using Optimization
lb = [0.0, 50.0, 0.0] # λ, K, u₀
ub = [0.05, 150.0, 50.0]
θ₀ = [λ, K, u₀]
syms = [:λ, :K, :u₀]
prob = LikelihoodProblem(
    loglik_fnc2, θ₀, ode_fnc, u₀, maximum(t); # Note that u₀ is just a placeholder IC in this case since we are estimating it
    syms=syms,
    data=(uᵒ, σ),
    ode_parameters=[1.0, 1.0], # temp values for [λ, K]
    ode_kwargs=(verbose=false, saveat=t),
    f_kwargs=(adtype=Optimization.AutoFiniteDiff(),),
    prob_kwargs=(lb=lb, ub=ub),
    ode_alg=Rosenbrock23()
)

## Step 3: Compute the MLE 
using OptimizationNLopt
sol = mle(prob, NLopt.LN_NELDERMEAD)

## Step 4: Profile 
prof = profile(prob, sol; alg=NLopt.LN_NELDERMEAD, parallel=false)

## Step 5: Visualise 
using CairoMakie, LaTeXStrings
fig = plot_profiles(prof;
    latex_names=[L"\lambda", L"K", L"u_0"],
    show_mles=true,
    shade_ci=true,
    nrow=1,
    ncol=3,
    true_vals=[λ, K, u₀],
    fig_kwargs=(fontsize=30, resolution=(2109.644f0, 444.242f0)),
    axis_kwargs=(width=600, height=300))

## Step 6: Get prediction intervals, compare to evaluating at many points 
function prediction_function(θ, data)
    λ, K, u₀ = θ
    t = data
    prob = ODEProblem(ode_fnc, u₀, extrema(t), (λ, K))
    sol = solve(prob, Rosenbrock23(), saveat=t)
    return sol.u
end
t_many_pts = LinRange(extrema(t)..., 1000)
parameter_wise, union_intervals, all_curves, param_range =
    get_prediction_intervals(prediction_function, prof,
        t_many_pts; parallel=true)

## Step 7: Plot the prediction intervals 
# Get the exact solution and MLE solutions first for comparison 
exact_soln = prediction_function([λ, K, u₀], t_many_pts)
mle_soln = prediction_function(get_mle(sol), t_many_pts)

# Now plot the prediction intervals
fig = Figure(fontsize=38, resolution=(1402.7681f0, 848.64404f0))
alp = join('a':'z')
latex_names = [L"\lambda", L"K", L"u_0"]
for i in 1:3
    ax = Axis(fig[i < 3 ? 1 : 2, i < 3 ? i : 1], title=L"(%$(alp[i])): Profile-wise PI for %$(latex_names[i])",
        titlealign=:left, width=600, height=300)
    [lines!(ax, t_many_pts, all_curves[i][:, j], color=:grey) for j in eachindex(param_range[1])]
    lines!(ax, t_many_pts, exact_soln, color=:red)
    lines!(ax, t_many_pts, mle_soln, color=:blue, linestyle=:dash)
    lines!(ax, t_many_pts, getindex.(parameter_wise[i], 1), color=:black, linewidth=3)
    lines!(ax, t_many_pts, getindex.(parameter_wise[i], 2), color=:black, linewidth=3)
end
ax = Axis(fig[2, 2], title=L"(d):$ $ Union of all intervals",
    titlealign=:left, width=600, height=300)
band!(ax, t_many_pts, getindex.(union_intervals, 1), getindex.(union_intervals, 2), color=:grey)
lines!(ax, t_many_pts, getindex.(union_intervals, 1), color=:black, linewidth=3)
lines!(ax, t_many_pts, getindex.(union_intervals, 2), color=:black, linewidth=3)
lines!(ax, t_many_pts, exact_soln, color=:red)
lines!(ax, t_many_pts, mle_soln, color=:blue, linestyle=:dash)

# We can now compare these intervals to the one obtained from the full likelihood. We re-use our grid_search code (see the next example) to evaluate at many points 
lb = get_lower_bounds(prob)
ub = get_upper_bounds(prob)
N = 1e5
grid = [[lb[i] + (ub[i] - lb[i]) * rand() for _ in 1:N] for i in 1:3]
grid = permutedims(reduce(hcat, grid), (2, 1))
ig = IrregularGrid(lb, ub, grid)
gs, lik_vals = grid_search(prob, ig; parallel=Val(true), save_vals=Val(true))
lik_vals .-= get_maximum(sol) # normalised 
feasible_idx = findall(lik_vals .> ProfileLikelihood.get_chisq_threshold(0.95)) # values in the confidence region 
parameter_evals = grid[:, feasible_idx]
q = [prediction_function(θ, t_many_pts) for θ in eachcol(parameter_evals)]
q_mat = reduce(hcat, q)
q_lwr = minimum(q_mat; dims=2) |> vec
q_upr = maximum(q_mat; dims=2) |> vec
lines!(ax, t_many_pts, q_lwr, color=:magenta, linewidth=3)
lines!(ax, t_many_pts, q_upr, color=:magenta, linewidth=3)
```
