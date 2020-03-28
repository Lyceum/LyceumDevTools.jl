module TestUtil

using BenchmarkTools: BenchmarkTools, memory
using MacroTools: MacroTools
using Test: Test

export @qe
export @test_inferred, @test_noalloc


"""
    @qe [expression]

Equivalent to:

    quote
        \$(MacroTools.striplines(esc(expression)))
    end
end
"""
macro qe(ex)
    Expr(:quote, MacroTools.striplines(esc(ex)))
end

macro test_inferred(ex)
    @qe begin
        $Test.@test (($Test.@inferred $ex); true)
    end
end

macro test_noalloc(ex)
    @qe begin
        local nbytes = $memory($BenchmarkTools.@benchmark $ex samples = 1 evals = 1)
        $iszero(nbytes) ? true : $error("Allocated $(BenchmarkTools.prettymemory(nbytes))")
    end
end

end # module
