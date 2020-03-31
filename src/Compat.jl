module Compat

using ..LyceumDevTools: gitauthurl, create_git_cmd, with_tempdir

using GitHub: Repo, Authorization, PullRequest, Branch
using GitHub: repo, authenticate, create_pull_request, edit_issue, pull_requests

using Dates
using Markdown: Markdown, Paragraph, Bold, Table, List, Header, HorizontalRule

using Pkg
using Pkg.Types: VersionSpec, VersionBound, semver_spec
using Pkg.Types: Context, EnvCache
using Pkg.Types: projectfile_path, manifestfile_path, write_project, write_manifest


export RepoSpec, CompatResult, update_tomls!


# "magic bytes" embedded in pull requests to identify if a preexisiting PR
const COMPAT_UUID = "0062fa4e-0639-437d-8ed2-9da17d9c0af2"
# For TagBot
const PR_LABELS = ["compat", "nochangelog"]

@static if VERSION < v"1.4"
    const BASE_PACKAGES = Set{Base.UUID}(x for x in keys(Pkg.Types.stdlib()))
else
    const BASE_PACKAGES = Set{Base.UUID}(x for x in keys(Pkg.Types.stdlibs()))
end

const DEFAULT_MASTERBRANCH = "master"
const DEFAULT_COMPATBRANCH = "compat"


Base.@kwdef struct RepoSpec
    reponame::String
    username::String
    token::String
    masterbranch::String = DEFAULT_MASTERBRANCH
    compatbranch::String = DEFAULT_COMPATBRANCH
    gitconfig::Dict{String,String} = Dict{String,String}()
end

mutable struct CompatResult
    new::Vector{Tuple{String,String}} # (name, new_compat)
    updated::Vector{Tuple{String,String,String}} # (name, old_compat, new_compat)
    unchanged::Vector{Tuple{String,String}} # (name, old_compat)
    julia_compat::Union{String,Nothing}
    manifest_updated::Bool

    function CompatResult()
        new(
            Vector{Tuple{String,String}}(),
            Vector{Tuple{String,String,String}}(),
            Vector{Tuple{String,String}}(),
            nothing,
            false,
        )
    end
end


function ghactions(; kwargs...)
    username = ENV["COMPAT_USERNAME"]
    spec = RepoSpec(
        reponame = ENV["GITHUB_REPOSITORY"],
        username = username,
        token = ENV["COMPAT_TOKEN"],
        masterbranch = get(ENV, "COMPAT_MASTERBRANCH", DEFAULT_MASTERBRANCH),
        compatbranch = get(ENV, "COMPAT_COMPATBRANCH", DEFAULT_COMPATBRANCH),
        gitconfig = Dict{String,String}("user.name" => username),
    )
    update_tomls!(spec; kwargs...)
    return nothing
end

function update_tomls!(rspec::RepoSpec; overwrite::Bool = true, kwargs...)
    masterbranch = rspec.masterbranch
    compatbranch = rspec.compatbranch

    gitcmd = create_git_cmd(rspec.gitconfig)
    @debug "Git command: $gitcmd"

    with_tempdir() do
        auth = authenticate(rspec.token)
        ghrepo = repo(rspec.reponame, auth = auth)

        url = gitauthurl(rspec.username, rspec.token, rspec.reponame)
        run(`$gitcmd clone $url repo`)
        cd("repo")

        run(`$gitcmd checkout $masterbranch`)
        run(`$gitcmd pull`)
        if overwrite
            run(`$gitcmd checkout -B $compatbranch`)
        else
            run(`$gitcmd checkout -b $compatbranch`)
        end

        result = update_tomls!(pwd(); kwargs...)

        shouldpush = (
            !isempty(result.new) ||
            !isempty(result.updated) || result.manifest_updated || result.julia_compat !== nothing
        )

        if shouldpush
            projectfile = projectfile_path(pwd())
            @debug "Project file: $projectfile"
            run(`$gitcmd add $projectfile`)

            if result.manifest_updated
                manifestfile = manifestfile_path(pwd())
                @debug "Manifest file: $manifestfile"
                run(`$gitcmd add $manifestfile`)
            end

            title = "New compat entries"
            body = string(format_message(result))

            run(`$gitcmd commit -m $title`)
            run(`$gitcmd push --force -u origin $compatbranch`)

            existing_pr = find_existing_pr(ghrepo, auth, compatbranch, masterbranch)
            if existing_pr === nothing
                params = Dict(
                    "title" => title,
                    "body" => body,
                    "labels" => PR_LABELS,
                    "head" => compatbranch,
                    "base" => masterbranch,
                )
                pr = create_pull_request(ghrepo; params = params, auth = auth)
                # NOTE: Adding labels when PR is created doesn't appear to work so
                # we edit it after creation.
                edit_issue(ghrepo, pr, params = Dict("labels" => PR_LABELS), auth = auth)
            else
                params = Dict("title" => title, "body" => body, "labels" => PR_LABELS)
                edit_issue(ghrepo, existing_pr, params = params, auth = auth)
            end
        else
            @info "No changes."
        end

        return result
    end
end

function find_existing_pr(repo::Repo, auth::Authorization, head::String, base::String)
    params = Dict(
        "state" => "open",
        "head" => "$(repo.owner.login):$head",
        "base" => base,
        "per_page" => 50,
        "page" => 1,
    )
    prs = Vector{PullRequest}()

    page_prs, page_data = pull_requests(repo, params = params, auth = auth)
    while true
        append!(prs, page_prs)
        if haskey(page_data, "next")
            page_prs, page_data = pull_requests(repo, auth = auth, start_page = page_data["next"])
        else
            break
        end
    end

    if isempty(prs)
        @debug "No PR found"
        return nothing
    elseif length(prs) == 1
        pr = first(prs)
        if occursin(COMPAT_UUID, pr.body)
            @info "Found existing PR"
            return pr
        else
            error("PR already exists but it wasn't created by Compat. Aborting.")
        end
    else
        error("More than one compat PR found. This shouldn't happen.")
    end
end

function format_message(r::CompatResult)
    msg = []
    push!(msg, Header("Summary", 3))

    misc = List()
    if r.manifest_updated
        push!(misc.items, Paragraph("Updated Manifest"))
    end
    if r.julia_compat !== nothing
        push!(misc.items, Paragraph("Updated compat entry for Julia: v$(r.julia_compat)"))
    end
    push!(misc.items, Paragraph("$(length(r.new)) new compat entries"))
    push!(misc.items, Paragraph("$(length(r.updated)) updated compat entries"))
    push!(misc.items, Paragraph("$(length(r.unchanged)) unchanged compat entries"))
    push!(msg, misc)

    if !isempty(r.new)
        push!(msg, Header("New Compat Entries", 3))
        titles = map(Bold, ["Package", "New Compat"])
        table = Markdown.Table([titles], [:l, :c])
        for (name, new) in r.new
            push!(table.rows, [name, new])
        end
        push!(msg, table)
    end

    if !isempty(r.updated)
        push!(msg, Header("Updated Compat Entries", 3))
        titles = map(Bold, ["Package", "Old Compat", "New Compat"])
        table = Markdown.Table([titles], [:l, :c, :c])
        for (name, old, new) in r.updated
            push!(table.rows, [name, old, new])
        end
        push!(msg, table)
    end

    # magic bytes for identifying if an existing PR came from LyceumDevTools.Compat
    push!(msg, HorizontalRule())
    push!(msg, Paragraph("Last updated: $(now())"))
    push!(msg, Paragraph("Magic Bytes: $COMPAT_UUID"))

    Markdown.MD(msg...)
end

function update_tomls!(
    pkgdir::AbstractString;
    keep_old_compat::Bool = true,
    update_manifest::Bool = true,
    drop_patch::Bool = true,
    update_julia_compat::Bool = false,
)
    @debug "Compat options" keep_old_compat update_manifest drop_patch update_julia_compat

    result = CompatResult()

    oldctx = Context(env = EnvCache(projectfile_path(pkgdir)))
    Pkg.instantiate(oldctx)
    Pkg.resolve(oldctx)

    newctx = Context(env = EnvCache(projectfile_path(pkgdir)))
    for (pkgname, entry) in newctx.env.project.compat
        pkgname == "julia" && continue
        # Prevent downgrading any deps below the lower bound of their current compat entry
        # by replacing each compat entry with an inequality specifier
        # e.g "0.2, 0.3, 0.5" --> ">= 0.2.0"
        newctx.env.project.compat[pkgname] = ">= $(lowerbound(semver_spec(entry)))"
    end
    Pkg.API.up(newctx, level = UPLEVEL_MAJOR, mode = PKGMODE_PROJECT, update_registry = true)


    for k in keys(oldctx.env.project.other)
        if k != "compat" && oldctx.env.project.other[k] != newctx.env.project.other[k]
            error("Corrupted project. Please file a bug report.")
        end
    end

    deps = oldctx.env.project.deps
    oldcompat = oldctx.env.project.compat
    newcompat = newctx.env.project.compat
    newmanifest = newctx.env.manifest
    for (pkgname, uuid) in deps
        (isstdlib(uuid) || isjll(pkgname)) && continue

        newversion = newmanifest[uuid].version

        if haskey(oldcompat, pkgname)
            oldentry = oldcompat[pkgname]

            if keep_old_compat
                newentry = format_compat(oldentry, newversion, drop_patch)
            else
                newentry = format_compat(newversion, drop_patch)
            end

            if semver_spec(oldentry) == semver_spec(newentry)
                # Same semver spec, but keep old entry formatting
                # TODO change this to provide a canoncial/compressed compat entry
                newentry = oldentry
                push!(result.unchanged, (pkgname, oldentry))
            else
                push!(result.updated, (pkgname, oldentry, newentry))
            end
        else
            newentry = format_compat(newversion, drop_patch)
            push!(result.new, (pkgname, newentry))
        end

        newcompat[pkgname] = newentry
    end

    if haskey(oldcompat, "julia") && !update_julia_compat
        newcompat["julia"] = oldcompat["julia"]
    else
        newcompat["julia"] = format_compat(VERSION, drop_patch)
        if get(oldcompat, "julia", nothing) != newcompat["julia"]
            result.julia_compat = newcompat["julia"]
        end
    end

    Pkg.Types.write_env(newctx.env)

    # Sanity check: resolve with updated compat entries
    newctx = Context(env = EnvCache(projectfile_path(pkgdir)))
    Pkg.resolve(newctx)
    # Sanity check: make sure we didn't downgrade any packages below their old compat entry
    for (pkgname, oldentry) in oldctx.env.project.compat
        pkgname == "julia" && continue
        uuid = newctx.env.project.deps[pkgname]
        if newctx.env.manifest[uuid].version < lowerbound(semver_spec(oldentry))
            error("Downgraded $pkgname below lower bound of old compat entry. Please file a bug report.")
        end
    end

    result.manifest_updated = update_manifest && oldctx.env.manifest != newmanifest

    return result
end

isstdlib(name::AbstractString) = isstdlib(Base.UUID(name))
isstdlib(uuid::Base.UUID) = uuid in BASE_PACKAGES
isjll(name::AbstractString) = endswith(lowercase(strip(name)), lowercase(strip("_jll"))) # TODO check for Artifacts.toml?

function format_compat(v::VersionNumber, drop_patch::Bool)
    if !(v.build == v.prerelease == ())
        throw(ArgumentError("version cannot have build or prerelease. Got: $v"))
    end

    if v.patch == 0 || drop_patch
        if v.minor == 0
            if v.major == 0 # v.major is 0, v.minor is 0, v.patch is 0
                throw(DomainError("0.0.0 is not a valid input"))
            else # v.major is nonzero and v.minor is 0 and v.patch is 0
                return "$(v.major)"
            end
        else # v.minor is nonzero, v.patch is 0
            return "$(v.major).$(v.minor)"
        end
    else # v.patch is nonzero
        return "$(v.major).$(v.minor).$(v.patch)"
    end
end

function format_compat(compat::AbstractString, drop_patch::Bool)
    compat = String(compat)
    try
        return format_compat(VersionNumber(compat))
    catch
        try
            spec = VersionSpec(semver_spec(compat)) # check to make sure valid
            @assert spec isa VersionSpec
            return String(strip(compat))
        catch
            throw(ArgumentError("not a valid compat entry: $compat"))
        end
    end
end

function format_compat(old, new, drop_patch)
    "$(format_compat(old, drop_patch)), $(format_compat(new, drop_patch))"
end

lowerbound(spec::VersionSpec) = minimum(r -> bound2ver(r.lower), spec.ranges)

function bound2ver(bound::VersionBound)
    bound.n == 0 && error("bound.n must be > 0 to convert to VersionNumber")
    return VersionNumber(bound[1], bound[2], bound[3])
end

end # module
