function ghactions(; kwargs...)
    username = ENV["COMPAT_USERNAME"]
    spec = RepoSpec(
        reponame = ENV["GITHUB_REPOSITORY"],
        username = username,
        token = ENV["COMPAT_TOKEN"],
        masterbranch = get(ENV, "COMPAT_MASTER_BRANCH", MASTER_BRANCH),
        compatbranch = get(ENV, "COMPAT_COMPAT_BRANCH", COMPAT_BRANCH),
        gitconfig = Dict{String,String}("user.name" => username),
    )
    update_tomls!(spec; kwargs...)
    return nothing
end
