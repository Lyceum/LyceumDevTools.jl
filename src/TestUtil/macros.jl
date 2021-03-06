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


macro includetests(testname)
    if __source__.file !== nothing
        _dirname = dirname(String(__source__.file::Symbol))
        root = isempty(_dirname) ? pwd() : abspath(_dirname)
    else
        root = pwd()
    end
    ex = quote
        if $isempty(ARGS)
            local testfiles = $filter(f -> $match(r"^test_.*\.jl$", $basename(f)) !== nothing, $flattendir($root, dirs=false, join=false))
        else
            local testfiles = $map(f -> $endswith(f, ".jl") ? f : "$f.jl", ARGS)
        end
        @includetests $testname testfiles
    end
    esc(ex)
end

macro includetests(testname, testfiles)
    ex = quote
        local testname = $testname
        $Test.@testset "$testname" begin
            for file in $testfiles
                $Test.@testset "$file" begin
                    $Base.include($__module__, file)
                end
            end
        end
    end
    esc(ex)
end