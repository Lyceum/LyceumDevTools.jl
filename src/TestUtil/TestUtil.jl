module TestUtil

using ..LyceumDevTools: flattendir

using BenchmarkTools: BenchmarkTools, memory
using Distributed: Distributed
using MacroTools: MacroTools
using Requires: @require

using Test: Test, AbstractTestSet, DefaultTestSet
using Test: Result, Pass, Fail, Error, Broken


export @qe
export @test_inferred, @test_noalloc
export @includetests
include("macros.jl")

export ProgressTestSet
include("progresstestset.jl")


function __init__()
    @require LyceumBase = "db31fed1-ca1e-4084-8a49-12fae1996a55" include("abstractenvironment.jl")
end

end # module
