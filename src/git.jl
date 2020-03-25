treehash(pkgdir::String) = Base.SHA1(Pkg.GitTools.tree_hash(pkgdir))
treehash(pkg::Module) = treehash(pkgdir(pkg))

function githttpsurl(url::AbstractString)
    m = match(LibGit2.URL_REGEX, url)
    LibGit2.git_url(scheme = "https", host = m[:host], path = m[:path])
end

create_git_cmd(config::AbstractDict; kwargs...) = create_git_cmd(pairs(config); kwargs...)
function create_git_cmd(config::Pair...; path = nothing)
    cmd = isnothing(path) ? ["git"] : ["git", "-C", path]
    for (n, v) in config
        push!(cmd, "-c")
        push!(cmd, "$n=$v")
    end
    Cmd(cmd)
end

gitauthurl(user, token, fullname) = "https://$(user):$(token)@github.com/$(fullname).git"

isdirty(repo_path::AbstractString) = LibGit2.isdirty(LibGit2.GitRepo(repo_path))

function repository_dispatch(
    repo::Repo,
    auth::Authorization,
    event_type::AbstractString = "dispatch";
    client_payload::Dict = Dict(),
    kwargs...,
)
    headers = Dict(
        "Accept" => "application/vnd.github.everest-preview+json",
        "Content-Type" => "application/json",
    )
    params = Dict("event_type" => event_type, "client_payload" => client_payload)
    result = GitHub.github_request(
        GitHub.DEFAULT_API,
        HTTP.post,
        "/repos/$(GitHub.name(repo))/dispatches";
        headers = headers,
        params = params,
        kwargs...,
    )
end
