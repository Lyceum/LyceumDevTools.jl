Base.@kwdef struct RepoSpec
    reponame::String # e.g "Lyceum/LyceumBase.jl"
    username::String
    token::String
    masterbranch::String = MASTER_BRANCH
    compatbranch::String = COMPAT_BRANCH
    gitconfig::Dict{String,String} = Dict{String,String}()
end

MaybeStr = Union{String,Nothing}
Base.@kwdef mutable struct CompatResult
    project_file::String
    # (name, new_compat)
    new::Vector{Tuple{String,String}} = Vector{Tuple{String,String}}()
    # (name, old_compat, new_compat)
    updated::Vector{Tuple{String,String,MaybeStr}} = Vector{Tuple{String,String,MaybeStr}}()
    # (name, old_compat)
    unchanged::Vector{Tuple{String,MaybeStr}} = Vector{Tuple{String,MaybeStr}}()
    julia_compat::MaybeStr = nothing
    manifest_updated::Bool = false
end

function project_updated(r::CompatResult)
    !isempty(r.new) || !isempty(r.updated) || r.julia_compat !== nothing
end
manifest_updated(r::CompatResult) = r.manifest_updated
updated(r::CompatResult) = project_updated(r) || manifest_updated(r)
