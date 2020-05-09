Base.@kwdef struct RepoSpec
    reponame::String
    username::String
    token::String
    masterbranch::String = MASTER_BRANCH
    compatbranch::String = COMPAT_BRANCH
    gitconfig::Dict{String,String} = Dict{String,String}()
end

mutable struct CompatResult
    new::Vector{Tuple{String,String}} # (name, new_compat)
    updated::Vector{Tuple{String,String,String}} # (name, old_compat, new_compat)
    unchanged::Vector{Tuple{String,String}} # (name, old_compat)
    julia_compat::Union{String,Nothing}
    project_file::Union{String,Nothing}
    manifest_file::Union{String,Nothing}

    function CompatResult()
        new(
            Vector{Tuple{String,String}}(),
            Vector{Tuple{String,String,String}}(),
            Vector{Tuple{String,String}}(),
            nothing,
            nothing,
            nothing,
        )
    end
end
