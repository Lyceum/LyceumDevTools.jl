function _trajectory(e::AbstractEnvironment, T::Integer)
    (
        states = Array(undef, statespace(e), T),
        obses = Array(undef, observationspace(e), T),
        acts = Array(undef, actionspace(e), T),
        rews = Array(undef, rewardspace(e), T),
    )
end

function _rollout(e::AbstractEnvironment, actions::AbstractMatrix)
    T = size(actions, 2)
    traj = _trajectory(e, T)
    traj.acts .= actions
    for t=1:T
        st = view(traj.states, :, t)
        at = view(traj.acts, :, t)
        ot = view(traj.obses, :, t)

        getstate!(st, e)
        getobservation!(ot, e)
        setaction!(e, at)
        traj.rews[t] = getreward(st, at, ot, e)
        step!(e)
    end
    traj
end


function testenv_correctness(etype::Type{<:AbstractEnvironment}, args...; kwargs...)
    makeenv() = etype(args...; kwargs...)
    randstate() = (e = makeenv(); randreset!(e); getstate(e))
    randobs() = (e = makeenv(); randreset!(e); getobservation(e))
    function randaction()
       e = makeenv()
       a = rand(actionspace(e)) .- 0.5 # random controllers in range [-0.5, 0.5]
       setaction!(e, a)
       # TODO hack for case where env has action limits until BoundedShape exists
       getaction!(a, e)
       return a
    end

    @testset "Interface" begin

        @test isconcretetype(typeof(makeenv()))

        @testset "time consistency" begin
            e = makeenv()
            @test time(e) isa Float64
            @test time(e) == 0 # time should always start from 0
            t1 = time(e)
            @test time(e) === t1
            @test step!(e) === e
            t2 = time(e)
            @test (t2 - t1) == timestep(e)
        end

        # For each of state/action/observation/reward, test:
        # 1. return type of getfoo(env) is compatible with foospace(env)
        # 2. getfoo!(x, env) returns x
        # 3. getfoo!(x, env) == getfoo(env)
        # 4. if settable, that setfoo!(env, x) returns env
        # 5. if settable, that getfoo(env) == x after setfoo!(env, x)
        # 6. all functions are inferrable

        @testset "state" begin
            let e = makeenv()
                @test statespace(e) isa Shapes.AbstractVectorShape
                @test eltype(getstate(e)) == eltype(statespace(e))
                @test eltype(getstate!(rand(statespace(e)), e)) == eltype(statespace(e))
                @test axes(getstate(e)) == axes(statespace(e))
                @test axes(getstate!(rand(statespace(e)), e)) == axes(statespace(e))
            end

            @test let e = makeenv(), x = rand(statespace(e))
                x === getstate!(x, e)
            end
            @test let e = makeenv()
                getstate!(rand(statespace(e)), e) == getstate(e)
            end

            @test let e = makeenv()
                e === setstate!(e, rand(statespace(e)))
            end
            @test let e = makeenv(), x = randstate()
                setstate!(e, x)
                x == getstate!(rand(statespace(e)), e) == getstate(e)
            end
        end

        @testset "action" begin
            let e = makeenv()
                @test actionspace(e) isa Shapes.AbstractVectorShape
                @test eltype(getaction(e)) == eltype(actionspace(e))
                @test eltype(getaction!(rand(actionspace(e)), e)) == eltype(actionspace(e))
                @test axes(getaction(e)) == axes(actionspace(e))
                @test axes(getaction!(rand(actionspace(e)), e)) == axes(actionspace(e))
            end

            @test let e = makeenv(), x = rand(actionspace(e))
                x === getaction!(x, e)
            end
            @test let e = makeenv()
                getaction!(rand(actionspace(e)), e) == getaction(e)
            end

            @test let e = makeenv()
                e === setaction!(e, rand(actionspace(e)))
            end
            @test let e = makeenv(), x = randaction()
                setaction!(e, x)
                x == getaction!(rand(actionspace(e)), e) == getaction(e)
            end
        end

        @testset "obs" begin
            let e = makeenv()
                @test observationspace(e) isa Shapes.AbstractVectorShape
                @test eltype(getobservation(e)) == eltype(observationspace(e))
                @test eltype(getobservation!(rand(observationspace(e)), e)) == eltype(observationspace(e))
                @test axes(getobservation(e)) == axes(observationspace(e))
                @test axes(getobservation!(rand(observationspace(e)), e)) == axes(observationspace(e))
            end

            @test let e = makeenv(), x = rand(observationspace(e))
                x === getobservation!(x, e)
            end
            @test let e = makeenv()
                getobservation!(rand(observationspace(e)), e) == getobservation(e)
            end
        end

        # For getreward and isdone, test that they are functions of the
        # passed in (state, action, observation) and not any internal data in the env.
        # NOTE requires that `randreset!` generating a new state with different
        # reward/isdone

        @testset "reward" begin
            let e = makeenv()
                @test rewardspace(e) isa ScalarShape
                @test typeof(getreward(e)) == eltype(rewardspace(e))
            end

            @test let e = makeenv(), s = getstate(e), a = getaction(e), o = getobservation(e)
                r1 = getreward(s, a, o, e)
                r2 = getreward(e)
                randreset!(e)
                r3 = getreward(s, a, o, e)
                r1 == r2 == r3
            end
        end

        @testset "isdone" begin
            @test let e = makeenv()
                isdone(e) isa Bool
            end

            @test let e = makeenv(), s = getstate(e), a = getaction(e), o = getobservation(e)
                d1 = isdone(s, o, e)
                d2 = isdone(e)
                randreset!(e)
                d3 = isdone(s, o, e)
                d1 == d2 == d3
            end
        end

        @testset "constructor consistency" begin
            e1, e2 = makeenv(), makeenv()
            @test getstate(e1) == getstate(e2)
            @test getaction(e1) == getaction(e2)
            @test getobservation(e1) == getobservation(e2)
            @test getreward(e1) == getreward(e2)
            @test isdone(e1) == isdone(e2)
        end

        @testset "reset" begin
            let e = makeenv()
                @test e === reset!(e)
            end

            let e1 = makeenv(), e2 = makeenv()
                setaction!(e1, rand(actionspace(e1)))
                setaction!(e2, rand(actionspace(e2)))
                for _=1:100
                    step!(e1)
                    step!(e2)
                end

                reset!(e1)
                reset!(e2)

                @test getstate(e1) == getstate(e2)
                @test getaction(e1) == getaction(e2)
                @test getobservation(e1) == getobservation(e2)
                @test getreward(e1) == getreward(e2)
                @test isdone(e1) == isdone(e2)
            end
        end

        @testset "randreset" begin
            let e = makeenv()
                @test e === randreset!(e)
                @test e === randreset!(Random.default_rng(), e)
            end

            let e1 = makeenv(), e2 = makeenv(), rng = Random.MersenneTwister()
                Random.seed!(rng, 1)
                randreset!(rng, e1)
                randreset!(rng, e2)

                @test getstate(e1) != getstate(e2)
                @test getaction(e1) == getaction(e2)
                @test getobservation(e1) != getobservation(e2)
                # TODO For some environments, resetting state may not yield
                # different reward
                # @test getreward(e1) != getreward(e2)
            end

            let e1 = makeenv(), e2 = makeenv(), rng = Random.MersenneTwister()
                Random.seed!(rng, 1)
                randreset!(rng, e1)
                Random.seed!(rng, 1)
                randreset!(rng, e2)

                @test getstate(e1) == getstate(e2)
                @test getaction(e1) == getaction(e2)
                @test getobservation(e1) == getobservation(e2)
                # TODO For some environments, resetting state may not yield
                # different reward
                # @test getreward(e1) == getreward(e2)
            end
        end

    end

    @testset "Determinism" begin
        # execute a random control _trajectory and check for repeatability
        let e1 = makeenv(), e2 = makeenv()
            actions = rand(actionspace(e1), 1000)
            reset!(e1)
            reset!(e2)
            t1 = _rollout(e1, actions)
            t2 = _rollout(e2, actions)
            reset!(e1)
            t3 = _rollout(e1, actions)
            @test t1 == t2 == t3
        end
    end
end

function testenv_allocations(etype::Type{<:AbstractEnvironment}, args...; kwargs...)
    @testset "Allocations" begin
        e = makeenv()
        s, a, o = getstate(e), getaction(e), getobservation(e)

        @test_noalloc statespace($e)
        @test_noalloc getstate!($s, $e)
        @test_noalloc setstate!($e, $s)

        @test_noalloc actionspace($e)
        @test_noalloc getaction!($a, $e)
        @test_noalloc setaction!($e, $a)

        @test_noalloc observationspace($e)
        @test_noalloc getobservation!($o, $e)

        @test_noalloc rewardspace($e)
        @test_noalloc getreward($s, $a, $o, $e)

        @test_noalloc reset!($e)
        @test_noalloc randreset!($e)
        @test_noalloc step!($e)
        @test_noalloc isdone($s, $o, $e)
        @test_noalloc time($e)
        @test_noalloc timestep($e)
    end
end

function testenv_inferred(etype::Type{<:AbstractEnvironment}, args...; kwargs...)
    @testset "Type Stability" begin
        e = makeenv()
        s, a, o = getstate(e), getaction(e), getobservation(e)

        @test_inferred statespace(e)
        @test_inferred getstate!(s, e)
        @test_inferred setstate!(e, s)

        @test_inferred actionspace(e)
        @test_inferred getaction!(a, e)
        @test_inferred setaction!(e, a)

        @test_inferred observationspace(e)
        @test_inferred getobservation!(o, e)

        @test_inferred rewardspace(e)
        @test_inferred getreward(s, a, o, e)

        @test_inferred reset!(e)
        @test_inferred randreset!(e)
        @test_inferred step!(e)
        @test_inferred isdone(s, o, e)
        @test_inferred time(e)
        @test_inferred timestep(e)
    end
end
