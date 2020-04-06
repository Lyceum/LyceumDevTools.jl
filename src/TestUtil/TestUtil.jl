module TestUtil

using ..LyceumDevTools: flattendir

using BenchmarkTools: BenchmarkTools, memory
using Distributed: Distributed
using LyceumBase
using MacroTools: MacroTools
using Random
using Shapes

using Test
using Test: AbstractTestSet, DefaultTestSet, Result, Pass, Fail, Error, Broken


export @qe
export @test_inferred, @test_noalloc
export @includetests
include("macros.jl")

export ProgressTestSet
include("progresstestset.jl")

include("abstractenvironment.jl")
export testenv_correctness, testenv_inferred, testenv_allocations

end # module
