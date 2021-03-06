using Test
using Bijectors
using Random
using LinearAlgebra
using ForwardDiff
using Tracker

using Bijectors: Log, Exp, Shift, Scale, Logit, SimplexBijector

Random.seed!(123)

struct NonInvertibleBijector{AD} <: ADBijector{AD, 1} end

contains(predicate::Function, b::Bijector) = predicate(b)
contains(predicate::Function, b::Composed) = any(contains.(predicate, b.ts))
contains(predicate::Function, b::Stacked) = any(contains.(predicate, b.bs))

# Scalar tests
@testset "<: ADBijector{AD}" begin
    (b::NonInvertibleBijector)(x) = clamp.(x, 0, 1)

    b = NonInvertibleBijector{Bijectors.ADBackend()}()
    @test_throws Bijectors.SingularJacobianException logabsdetjac(b, [1.0, 10.0])
end

@testset "Univariate" begin
    # Tests with scalar-valued distributions.
    uni_dists = [
        Arcsine(2, 4),
        Beta(2,2),
        BetaPrime(),
        Biweight(),
        Cauchy(),
        Chi(3),
        Chisq(2),
        Cosine(),
        Epanechnikov(),
        Erlang(),
        Exponential(),
        FDist(1, 1),
        Frechet(),
        Gamma(),
        InverseGamma(),
        InverseGaussian(),
        # Kolmogorov(),
        Laplace(),
        Levy(),
        Logistic(),
        LogNormal(1.0, 2.5),
        Normal(0.1, 2.5),
        Pareto(),
        Rayleigh(1.0),
        TDist(2),
        TruncatedNormal(0, 1, -Inf, 2),
    ]
    
    for dist in uni_dists
        @testset "$dist: dist" begin
            td = transformed(dist)

            # single sample
            y = rand(td)
            x = inv(td.transform)(y)
            @test y == td.transform(x)
            @test logpdf(td, y) ≈ logpdf_with_trans(dist, x, true)

            # logpdf_with_jac
            lp, logjac = logpdf_with_jac(td, y)
            @test lp ≈ logpdf(td, y)
            @test logjac ≈ logabsdetjacinv(td.transform, y)

            # multi-sample
            y = rand(td, 10)
            x = inv(td.transform).(y)
            @test logpdf.(td, y) ≈ logpdf_with_trans.(dist, x, true)

            # logpdf corresponds to logpdf_with_trans
            d = dist
            b = bijector(d)
            x = rand(d)
            y = b(x)
            @test logpdf(d, inv(b)(y)) + logabsdetjacinv(b, y) ≈ logpdf_with_trans(d, x, true)
            @test logpdf(d, x) - logabsdetjac(b, x) ≈ logpdf_with_trans(d, x, true)

            # forward
            f = forward(td)
            @test f.x ≈ inv(td.transform)(f.y)
            @test f.y ≈ td.transform(f.x)
            @test f.logabsdetjac ≈ logabsdetjac(td.transform, f.x)
            @test f.logpdf ≈ logpdf_with_trans(td.dist, f.x, true)
            @test f.logpdf ≈ logpdf(td.dist, f.x) - f.logabsdetjac

            # verify against AD
            d = dist
            b = bijector(d)
            x = rand(d)
            y = b(x)
            @test log(abs(ForwardDiff.derivative(b, x))) ≈ logabsdetjac(b, x)
            @test log(abs(ForwardDiff.derivative(inv(b), y))) ≈ logabsdetjac(inv(b), y)
        end

        @testset "$dist: ForwardDiff AD" begin
            x = rand(dist)
            b = DistributionBijector{Bijectors.ADBackend(:forward_diff), typeof(dist), length(size(dist))}(dist)
            
            @test abs(det(Bijectors.jacobian(b, x))) > 0
            @test logabsdetjac(b, x) ≠ Inf

            y = b(x)
            b⁻¹ = inv(b)
            @test abs(det(Bijectors.jacobian(b⁻¹, y))) > 0
            @test logabsdetjac(b⁻¹, y) ≠ Inf
        end

        @testset "$dist: Tracker AD" begin
            x = rand(dist)
            b = DistributionBijector{Bijectors.ADBackend(:reverse_diff), typeof(dist), length(size(dist))}(dist)
            
            @test abs(det(Bijectors.jacobian(b, x))) > 0
            @test logabsdetjac(b, x) ≠ Inf

            y = b(x)
            b⁻¹ = inv(b)
            @test abs(det(Bijectors.jacobian(b⁻¹, y))) > 0
            @test logabsdetjac(b⁻¹, y) ≠ Inf
        end
    end
end

@testset "Batch computation" begin
    bs_xs = [
        (Scale(2.0), randn(3)),
        (Scale([1.0, 2.0]), randn(2, 3)),
        (Shift(2.0), randn(3)),
        (Shift([1.0, 2.0]), randn(2, 3)),
        (Log{0}(), exp.(randn(3))),
        (Log{1}(), exp.(randn(2, 3))),
        (Exp{0}(), randn(3)),
        (Exp{1}(), randn(2, 3)),
        (Log{1}() ∘ Exp{1}(), randn(2, 3)),
        (inv(Logit(-1.0, 1.0)), randn(3)),
        (Identity{0}(), randn(3)),
        (Identity{1}(), randn(2, 3)),
        (PlanarLayer(2), randn(2, 3)),
        (RadialLayer(2), randn(2, 3)),
        (PlanarLayer(2) ∘ RadialLayer(2), randn(2, 3)),
        (Exp{1}() ∘ PlanarLayer(2) ∘ RadialLayer(2), randn(2, 3)),
        (SimplexBijector(), mapslices(z -> normalize(z, 1), rand(2, 3); dims = 1)),
        (stack(Exp{0}(), Scale(2.0)), randn(2, 3)),
        (Stacked((Exp{1}(), SimplexBijector()), [1:1, 2:3]),
         mapslices(z -> normalize(z, 1), rand(3, 2); dims = 1))
    ]

    for (b, xs) in bs_xs
        @testset "$b" begin
            D = Bijectors.dimension(b)
            ib = inv(b)

            @test Bijectors.dimension(ib) == D

            x = D == 0 ? xs[1] : xs[:, 1]

            y = b(x)
            ys = b(xs)

            x_ = ib(y)
            xs_ = ib(ys)

            result = forward(b, x)
            results = forward(b, xs)

            iresult = forward(ib, y)
            iresults = forward(ib, ys)

            # Sizes
            @test size(y) == size(x)
            @test size(ys) == size(xs)

            @test size(x_) == size(x)
            @test size(xs_) == size(xs)

            @test size(result.rv) == size(x)
            @test size(results.rv) == size(xs)

            @test size(iresult.rv) == size(y)
            @test size(iresults.rv) == size(ys)

            # Values
            @test ys == mapslices(z -> b(z), xs; dims = 1)
            @test ys ≈ results.rv

            if D == 0
                # Sizes
                @test y == ys[1]

                @test length(logabsdetjac(b, xs)) == length(xs)
                @test length(logabsdetjac(ib, ys)) == length(xs)

                @test size(results.logabsdetjac) == size(xs, )
                @test size(iresults.logabsdetjac) == size(ys, )

                # Values
                b_logjac_ad = [(log ∘ abs)(ForwardDiff.derivative(b, xs[i])) for i = 1:length(xs)]
                ib_logjac_ad = [(log ∘ abs)(ForwardDiff.derivative(ib, ys[i])) for i = 1:length(ys)]
                @test logabsdetjac.(b, xs) == logabsdetjac(b, xs)
                @test logabsdetjac(b, xs) ≈ b_logjac_ad atol=1e-9
                @test logabsdetjac.(ib, ys) == logabsdetjac(ib, ys)
                @test logabsdetjac(ib, ys) ≈ ib_logjac_ad atol=1e-9

                @test results.logabsdetjac ≈ vec(logabsdetjac.(b, xs))
                @test iresults.logabsdetjac ≈ vec(logabsdetjac.(ib, ys))
            elseif D == 1
                @test y == ys[:, 1]
                # Comparing sizes instead of lengths ensures we catch errors s.t.
                # length(x) == 3 when size(x) == (1, 3).
                # Sizes
                @test size(logabsdetjac(b, xs)) == (size(xs, 2), )
                @test size(logabsdetjac(ib, ys)) == (size(xs, 2), )

                @test size(results.logabsdetjac) == (size(xs, 2), )
                @test size(iresults.logabsdetjac) == (size(ys, 2), )

                # Test all values
                @test logabsdetjac(b, xs) == vec(mapslices(z -> logabsdetjac(b, z), xs; dims = 1))
                @test logabsdetjac(ib, ys) == vec(mapslices(z -> logabsdetjac(ib, z), ys; dims = 1))

                @test results.logabsdetjac ≈ vec(mapslices(z -> logabsdetjac(b, z), xs; dims = 1))
                @test iresults.logabsdetjac ≈ vec(mapslices(z -> logabsdetjac(ib, z), ys; dims = 1))

                # some have issues with numerically solving the inverse
                # FIXME: `SimplexBijector` results in ∞ gradient if not in the domain
                if isclosedform(b) && !contains(t -> t isa SimplexBijector, b)
                    b_logjac_ad = [logabsdet(ForwardDiff.jacobian(b, xs[:, i]))[1] for i = 1:size(xs, 2)]
                    @test logabsdetjac(b, xs) ≈ b_logjac_ad atol=1e-9
                end

                if isclosedform(inv(b)) && !contains(t -> t isa SimplexBijector, b)
                    ib_logjac_ad = [logabsdet(ForwardDiff.jacobian(ib, ys[:, i]))[1] for i = 1:size(ys, 2)]
                    @test logabsdetjac(ib, ys) ≈ ib_logjac_ad atol=1e-9
                end
            else
                error("tests not implemented yet")
            end
        end
    end

    @testset "Composition" begin
        @test_throws DimensionMismatch (Exp{1}() ∘ Log{0}())
    end

    @testset "Batch-computation with Tracker.jl" begin
        @testset "Scale" begin
            # 0-dim with `Real` parameter
            b = Scale(param(2.0))
            lj = logabsdetjac(b, 1.0)
            Tracker.back!(lj, 1.0)
            @test Tracker.extract_grad!(b.a) == 0.5

            # 0-dim with `Real` parameter for batch-computation
            lj = logabsdetjac(b, [1.0, 2.0, 3.0])
            Tracker.back!(lj, [1.0, 1.0, 1.0])
            @test Tracker.extract_grad!(b.a) == sum([0.5, 0.5, 0.5])


            # 1-dim with `Vector` parameter
            b = Scale(param([2.0, 3.0, 5.0]))
            lj = logabsdetjac(b, [3.0, 4.0, 5.0])
            Tracker.back!(lj)
            @test Tracker.extract_grad!(b.a) == fill(sum(inv.(b.a)), 3)

            lj = logabsdetjac(b, [3.0 4.0 5.0; 6.0 7.0 8.0])
            Tracker.back!(lj, [1.0, 1.0, 1.0])
            @test Tracker.extract_grad!(b.a) == fill(sum(inv.(b.a)), 3) .* 3
        end

        @testset "Shift" begin
            b = Shift(param(1.0))
            lj = logabsdetjac(b, 1.0)
            Tracker.back!(lj, 1.0)
            @test Tracker.extract_grad!(b.a) == 0.0

            # 0-dim with `Real` parameter for batch-computation
            lj = logabsdetjac(b, [1.0, 2.0, 3.0])
            Tracker.back!(lj, [1.0, 1.0, 1.0])
            @test Tracker.extract_grad!(b.a) == 0.0

            # 1-dim with `Vector` parameter
            b = Shift(param([2.0, 3.0, 5.0]))
            lj = logabsdetjac(b, [3.0, 4.0, 5.0])
            Tracker.back!(lj)
            @test Tracker.extract_grad!(b.a) == zeros(3)

            lj = logabsdetjac(b, [3.0 4.0 5.0; 6.0 7.0 8.0])
            Tracker.back!(lj, [1.0, 1.0, 1.0])
            @test Tracker.extract_grad!(b.a) == zeros(3)
        end
    end
end

@testset "Truncated" begin
    d = Truncated(Normal(), -1, 1)
    b = bijector(d)
    x = rand(d)
    y = b(x)
    @test y ≈ link(d, x)
    @test inv(b)(y) ≈ x
    @test logabsdetjac(b, x) ≈ logpdf_with_trans(d, x, false) - logpdf_with_trans(d, x, true)

    d = Truncated(Normal(), -Inf, 1)
    b = bijector(d)
    x = rand(d)
    y = b(x)
    @test y ≈ link(d, x)
    @test inv(b)(y) ≈ x
    @test logabsdetjac(b, x) ≈ logpdf_with_trans(d, x, false) - logpdf_with_trans(d, x, true)

    d = Truncated(Normal(), 1, Inf)
    b = bijector(d)
    x = rand(d)
    y = b(x)
    @test y ≈ link(d, x)
    @test inv(b)(y) ≈ x
    @test logabsdetjac(b, x) ≈ logpdf_with_trans(d, x, false) - logpdf_with_trans(d, x, true)
end

@testset "Multivariate" begin
    vector_dists = [
        Dirichlet(2, 3),
        Dirichlet([1000 * one(Float64), eps(Float64)]),
        Dirichlet([eps(Float64), 1000 * one(Float64)]),
        MvNormal(randn(10), exp.(randn(10))),
        MvLogNormal(MvNormal(randn(10), exp.(randn(10)))),
        Dirichlet([1000 * one(Float64), eps(Float64)]), 
        Dirichlet([eps(Float64), 1000 * one(Float64)]),
    ]

    for dist in vector_dists
        @testset "$dist: dist" begin
            dist = Dirichlet([eps(Float64), 1000 * one(Float64)])
            td = transformed(dist)

            # single sample
            y = rand(td)
            x = inv(td.transform)(y)
            @test y == td.transform(x)
            @test logpdf(td, y) ≈ logpdf_with_trans(dist, x, true)

            # logpdf_with_jac
            lp, logjac = logpdf_with_jac(td, y)
            @test lp ≈ logpdf(td, y)
            @test logjac ≈ logabsdetjacinv(td.transform, y)

            # multi-sample
            y = rand(td, 10)
            x = inv(td.transform)(y)
            @test logpdf(td, y) ≈ logpdf_with_trans(dist, x, true)

            # forward
            f = forward(td)
            @test f.x ≈ inv(td.transform)(f.y)
            @test f.y ≈ td.transform(f.x)
            @test f.logabsdetjac ≈ logabsdetjac(td.transform, f.x)
            @test f.logpdf ≈ logpdf_with_trans(td.dist, f.x, true)

            # verify against AD
            # similar to what we do in test/transform.jl for Dirichlet
            if dist isa Dirichlet
                b = Bijectors.SimplexBijector{Val{false}}()
                x = rand(dist)
                y = b(x)
                @test log(abs(det(ForwardDiff.jacobian(b, x)))) ≈ logabsdetjac(b, x)
                @test log(abs(det(ForwardDiff.jacobian(inv(b), y)))) ≈ logabsdetjac(inv(b), y)
            else
                b = bijector(dist)
                x = rand(dist)
                y = b(x)
                @test log(abs(det(ForwardDiff.jacobian(b, x)))) ≈ logabsdetjac(b, x)
                @test log(abs(det(ForwardDiff.jacobian(inv(b), y)))) ≈ logabsdetjac(inv(b), y)
            end
        end
    end
end

@testset "Matrix variate" begin
    v = 7.0
    S = Matrix(1.0I, 2, 2)
    S[1, 2] = S[2, 1] = 0.5

    matrix_dists = [
        Wishart(v,S),
        InverseWishart(v,S)
    ]

    for dist in matrix_dists
        @testset "$dist: dist" begin
            td = transformed(dist)

            # single sample
            y = rand(td)
            x = inv(td.transform)(y)
            @test logpdf(td, y) ≈ logpdf_with_trans(dist, x, true)

            # TODO: implement `logabsdetjac` for these
            # logpdf_with_jac
            # lp, logjac = logpdf_with_jac(td, y)
            # @test lp ≈ logpdf(td, y)
            # @test logjac ≈ logabsdetjacinv(td.transform, y)

            # multi-sample
            y = rand(td, 10)
            x = inv(td.transform)(y)
            @test logpdf(td, y) ≈ logpdf_with_trans(dist, x, true)
        end
    end
end

@testset "Composition <: Bijector" begin
    d = Beta()
    td = transformed(d)

    x = rand(d)
    y = td.transform(x)

    b = Bijectors.composel(td.transform, Bijectors.Identity{0}())
    ib = inv(b)

    @test forward(b, x) == forward(td.transform, x)
    @test forward(ib, y) == forward(inv(td.transform), y)

    @test forward(b, x) == forward(Bijectors.composer(b.ts...), x)

    # inverse works fine for composition
    cb = b ∘ ib
    @test cb(x) ≈ x

    cb2 = cb ∘ cb
    @test cb(x) ≈ x

    # ensures that the `logabsdetjac` is correct
    x = rand(d)
    b = inv(bijector(d))
    @test logabsdetjac(b ∘ b, x) ≈ logabsdetjac(b, b(x)) + logabsdetjac(b, x)

    # order of composed evaluation
    b1 = DistributionBijector(d)
    b2 = DistributionBijector(Gamma())

    cb = b1 ∘ b2
    @test cb(x) ≈ b1(b2(x))

    # contrived example
    b = bijector(d)
    cb = inv(b) ∘ b
    cb = cb ∘ cb
    @test (cb ∘ cb ∘ cb ∘ cb ∘ cb)(x) ≈ x

    # forward for tuple and array
    d = Beta()
    b = inv(bijector(d))
    b⁻¹ = inv(b)
    x = rand(d)

    cb_t = b⁻¹ ∘ b⁻¹
    f_t = forward(cb_t, x)

    cb_a = Composed([b⁻¹, b⁻¹])
    f_a = forward(cb_a, x)

    @test f_t == f_a

    # `composer` and `composel`
    cb_l = Bijectors.composel(b⁻¹, b⁻¹, b)
    cb_r = Bijectors.composer(reverse(cb_l.ts)...)
    y = cb_l(x)
    @test y == Bijectors.composel(cb_r.ts...)(x)

    k = length(cb_l.ts)
    @test all([cb_l.ts[i] == cb_r.ts[i] for i = 1:k])
end

@testset "Stacked <: Bijector" begin
    # `logabsdetjac` withOUT AD
    d = Beta()
    b = bijector(d)
    x = rand(d)
    y = b(x)

    sb1 = stack(b, b, inv(b), inv(b))             # <= Tuple
    res1 = forward(sb1, [x, x, y, y])

    @test sb1([x, x, y, y]) == res1.rv
    @test logabsdetjac(sb1, [x, x, y, y]) ≈ 0.0
    @test res1.logabsdetjac ≈ 0.0

    sb2 = Stacked([b, b, inv(b), inv(b)])        # <= Array
    res2 = forward(sb2, [x, x, y, y])

    @test sb2([x, x, y, y]) == res2.rv
    @test logabsdetjac(sb2, [x, x, y, y]) ≈ 0.0
    @test res2.logabsdetjac ≈ 0.0

    # `logabsdetjac` with AD
    b = DistributionBijector(d)
    y = b(x)
    
    sb1 = stack(b, b, inv(b), inv(b))             # <= Tuple
    res1 = forward(sb1, [x, x, y, y])

    @test sb1([x, x, y, y]) == res1.rv
    @test logabsdetjac(sb1, [x, x, y, y]) ≈ 0.0
    @test res1.logabsdetjac ≈ 0.0

    sb2 = Stacked([b, b, inv(b), inv(b)])        # <= Array
    res2 = forward(sb2, [x, x, y, y])

    @test sb2([x, x, y, y]) == res2.rv
    @test logabsdetjac(sb2, [x, x, y, y]) ≈ 0.0
    @test res2.logabsdetjac ≈ 0.0

    # value-test
    x = ones(3)
    sb = stack(Bijectors.Exp(), Bijectors.Log(), Bijectors.Shift(5.0))
    res = forward(sb, x)
    @test sb(x) == [exp(x[1]), log(x[2]), x[3] + 5.0]
    @test res.rv == [exp(x[1]), log(x[2]), x[3] + 5.0]
    @test logabsdetjac(sb, x) == sum([sum(logabsdetjac(sb.bs[i], x[sb.ranges[i]])) for i = 1:3])
    @test res.logabsdetjac == logabsdetjac(sb, x)
    

    # TODO: change when we have dimensionality in the type
    sb = Stacked((Bijectors.Exp(), Bijectors.SimplexBijector()), [1:1, 2:3])
    x = ones(3) ./ 3.0
    res = forward(sb, x)
    @test sb(x) == [exp(x[1]), sb.bs[2](x[2:3])...]
    @test res.rv == [exp(x[1]), sb.bs[2](x[2:3])...]
    @test logabsdetjac(sb, x) == sum([sum(logabsdetjac(sb.bs[i], x[sb.ranges[i]])) for i = 1:2])
    @test res.logabsdetjac == logabsdetjac(sb, x)

    x = ones(4) ./ 4.0
    @test_throws AssertionError sb(x)

    @test_throws AssertionError Stacked([Bijectors.Exp(), ], (1:1, 2:3))
    @test_throws MethodError Stacked((Bijectors.Exp(), ), (1:1, 2:3))

    @testset "Stacked: ADVI with MvNormal" begin
        # MvNormal test
        dists = [
            Beta(),
            Beta(),
            Beta(),
            InverseGamma(),
            InverseGamma(),
            Gamma(),
            Gamma(),
            InverseGamma(),
            Cauchy(),
            Gamma(),
            MvNormal(zeros(2), ones(2))
        ]

        ranges = []
        idx = 1
        for i = 1:length(dists)
            d = dists[i]
            push!(ranges, idx:idx + length(d) - 1)
            idx += length(d)
        end

        num_params = ranges[end][end]
        d = MvNormal(zeros(num_params), ones(num_params))

        # Stacked{<:Array}
        bs = bijector.(dists)     # constrained-to-unconstrained bijectors for dists
        ibs = inv.(bs)            # invert, so we get unconstrained-to-constrained
        sb = Stacked(ibs, ranges) # => Stacked <: Bijector
        x = rand(d)

        @test sb isa Stacked

        td = transformed(d, sb)  # => MultivariateTransformed <: Distribution{Multivariate, Continuous}
        @test td isa Distribution{Multivariate, Continuous}

        # check that wrong ranges fails
        @test_throws MethodError stack(ibs...)
        sb = Stacked(ibs)
        x = rand(d)
        @test_throws AssertionError sb(x)

        # Stacked{<:Tuple}
        bs = bijector.(tuple(dists...))
        ibs = inv.(bs)
        sb = Stacked(ibs, ranges)
        isb = inv(sb)
        @test sb isa Stacked{<: Tuple}

        # inverse
        td = transformed(d, sb)
        y = rand(td)
        x = isb(y)
        @test sb(x) ≈ y

        # verification of computation
        x = rand(d)
        y = sb(x)
        y_ = vcat([ibs[i](x[ranges[i]]) for i = 1:length(dists)]...)
        x_ = vcat([bs[i](y[ranges[i]]) for i = 1:length(dists)]...)
        @test x ≈ x_
        @test y ≈ y_

        # AD verification
        @test log(abs(det(ForwardDiff.jacobian(sb, x)))) ≈ logabsdetjac(sb, x)
        @test log(abs(det(ForwardDiff.jacobian(isb, y)))) ≈ logabsdetjac(isb, y)
    end
end

@testset "Example: ADVI single" begin
    # Usage in ADVI
    d = Beta()
    b = DistributionBijector(d)    # [0, 1] → ℝ
    ib = inv(b)                    # ℝ → [0, 1]
    td = transformed(Normal(), ib) # x ∼ 𝓝(0, 1) then f(x) ∈ [0, 1]
    x = rand(td)                   # ∈ [0, 1]
    @test 0 ≤ x ≤ 1
end

