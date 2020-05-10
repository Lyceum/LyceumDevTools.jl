module Compat

using ..LyceumDevTools: gitauthurl, create_git_cmd
using ..LyceumDevTools: with_tempdir, issubpath

using GitHub: Repo, Authorization, PullRequest, Branch
using GitHub: repo, authenticate, create_pull_request, edit_issue, pull_requests

using Dates
using Markdown: Markdown, Paragraph, Bold, Table, List, Header, HorizontalRule

using Pkg
using Pkg.Types: VersionSpec, VersionBound, semver_spec
using Pkg.Types: Context, EnvCache, Project, Manifest
using Pkg.Types: projectfile_path, manifestfile_path, write_env, write_project, write_manifest

using UnPack


export RepoSpec, update_tomls!, update_tomls_from_sub_dir!, ghactions


# "magic bytes" embedded in pull requests to identify if a preexisiting PR
const COMPAT_UUID = "0062fa4e-0639-437d-8ed2-9da17d9c0af2"
# For TagBot
const PR_LABELS = ["compat", "nochangelog"]

@static if VERSION < v"1.4"
    const BASE_PACKAGES = Set{Base.UUID}(x for x in keys(Pkg.Types.stdlib()))
else
    const BASE_PACKAGES = Set{Base.UUID}(x for x in keys(Pkg.Types.stdlibs()))
end

const MASTER_BRANCH = "master"
const COMPAT_BRANCH = "compat"
const UPDATE_MANIFEST = true
const KEEP_OLD_COMPAT = true
const DROP_PATCH = true
const UPDATE_JULIA_COMPAT = false
const SHARE_TRACKED_DEPS = false


include("types.jl")
include("ci.jl")
include("util.jl")


function update_tomls!(
    env_dir::AbstractString;
    keep_old_compat::Bool = KEEP_OLD_COMPAT,
    drop_patch::Bool = DROP_PATCH,
    update_julia_compat::Bool = UPDATE_JULIA_COMPAT,
)
    ctx = Context(env = EnvCache(projectfile_path(env_dir)))
    _lowerbound!(ctx)
    Pkg.resolve()
    Pkg.API.up(ctx, level = UPLEVEL_MAJOR, mode = PKGMODE_PROJECT, update_registry = true)
    _unlowerbound!(ctx)

    result = _update_tomls!(ctx, ctx, keep_old_compat, drop_patch, update_julia_compat, false)

    msg = format_message(nothing => result)
    println()
    display(msg)

    return (result, ), msg
end

function update_tomls_from_sub_dir!(
    pkg_dir::AbstractString,
    sub_dir::AbstractString;
    keep_old_compat::Bool = KEEP_OLD_COMPAT,
    drop_patch::Bool = DROP_PATCH,
    update_julia_compat::Bool = UPDATE_JULIA_COMPAT,
    share_tracked_deps::Bool = SHARE_TRACKED_DEPS,
)
    sub_dir = normpath(joinpath(pkg_dir, sub_dir))
    isdir(sub_dir) || error("$sub_dir does not exist.")
    issubpath(pkg_dir, sub_dir) || error("$sub_dir is not a subdirectory of $pkg_dir")

    pkg_ctx = Context(env = EnvCache(projectfile_path(pkg_dir)))
    sub_ctx = Context(env = EnvCache(projectfile_path(sub_dir)))
    isfile(sub_ctx.env.project_file) || error("No Project.toml found in $sub_dir")

    # Check that the package is dev'ed relative to sub_dir
    Pkg.instantiate(sub_ctx)
    pkg_name = pkg_ctx.env.project.name
    pkg_entry = get(sub_ctx.env.manifest, pkg_ctx.env.project.uuid, nothing)
    pkg_entry === nothing && error("$pkg_name not found in $(sub_ctx.env.manifest_file)")
    expected = relpath(pkg_dir, sub_dir)
    pkg_entry.path == expected || error("Expected $pkg_name to be dev'ed at $expected.")

    # relax compat for both the project and sub-project and get the updated manifest
    _lowerbound!(pkg_ctx)
    _lowerbound!(sub_ctx)
    Pkg.resolve(sub_ctx)
    Pkg.API.up(sub_ctx, level = UPLEVEL_MAJOR, mode = PKGMODE_PROJECT, update_registry = true)
    _unlowerbound!(pkg_ctx)
    _unlowerbound!(sub_ctx)

    pkg_result = _update_tomls!(pkg_ctx, sub_ctx, keep_old_compat, drop_patch, update_julia_compat, share_tracked_deps)
    sub_result = _update_tomls!(sub_ctx, sub_ctx, keep_old_compat, drop_patch, update_julia_compat, false)

    msg = format_message("/" => pkg_result, "/" * relpath(sub_dir, pkg_dir) => sub_result)
    println()
    display(msg)

    return (pkg_result, sub_result), msg
end

function _lowerbound!(ctx::Context)
    for (name, entry) in ctx.env.project.compat
        name == "julia" && continue
        # Prevent downgrading any deps below the lower bound of their current compat entry
        # by replacing each compat entry with an inequality specifier
        # e.g "0.2, 0.3, 0.5" --> ">= 0.2.0"
        ctx.env.project.compat[name] = ">= $(lowerbound(semver_spec(entry)))"
    end
    write_env(ctx.env)
    return ctx
end

function _unlowerbound!(ctx::Context)
    for (name, entry) in ctx.env.project.compat
        name == "julia" && continue
        ctx.env.project.compat[name] = ctx.env.original_project.compat[name]
    end
    write_env(ctx.env)
    return ctx
end

function _update_tomls!(
    dest::Context,
    src::Context,
    keep_old_compat::Bool,
    drop_patch::Bool,
    update_julia_compat::Bool,
    share_tracked_deps::Bool,
)
    deps = dest.env.project.deps
    old_compat = dest.env.original_project.compat
    new_compat = dest.env.project.compat
    new_manifest = src.env.manifest
    result = CompatResult()

    for (name, uuid) in deps
        (isstdlib(uuid) || isjll(name)) && continue

        new_pkg_entry = new_manifest[uuid]
        new_version = new_manifest[uuid].version
        if share_tracked_deps
            dest.env.manifest[uuid] = new_pkg_entry
        end

        if haskey(old_compat, name)
            old_entry = old_compat[name]
            if keep_old_compat
                new_entry = format_compat(old_entry, new_version, drop_patch)
            else
                new_entry = format_compat(new_version, drop_patch)
            end
            if semver_spec(old_entry) == semver_spec(new_entry)
                # Same semver spec, but keep old entry formatting
                # TODO change this to provide a canoncial/compressed compat entry
                new_entry = old_entry
                push!(result.unchanged, (name, old_entry))
            else
                push!(result.updated, (name, old_entry, new_entry))
            end
            # sanity check: make sure we don't downgrade any packages below their old compat entry
            old_lb = lowerbound(semver_spec(old_entry))
            new_lb = lowerbound(semver_spec(new_entry))
            @assert old_lb <= new_lb
        else
            new_entry = format_compat(new_version, drop_patch)
            push!(result.new, (name, new_entry))
        end
        new_compat[name] = new_entry
    end

    if !haskey(old_compat, "julia")
        new_compat["julia"] = format_compat(VERSION, drop_patch)
        result.julia_compat = new_compat["julia"]
    elseif update_julia_compat
        new_compat["julia"] = format_compat(VERSION, drop_patch)
        if get(old_compat, "julia", nothing) != new_compat["julia"]
            result.julia_compat = new_compat["julia"]
        end
    end

    # sanity check: make sure project can still be resolved (Pkg.resolve errors if not)
    Pkg.resolve(dest)
    Pkg.API.up(dest, level = UPLEVEL_MAJOR, mode = PKGMODE_PROJECT, update_registry = true)
    write_env(dest.env)

    result.project_file = dest.env.project_file
    if dest.env.manifest != dest.env.original_manifest
        result.manifest_file = dest.env.manifest_file
    end

    return result
end



function update_tomls!(rspec::RepoSpec; sub_dir = nothing, commit_manifest::Bool = true, overwrite::Bool = true, kwargs...)
    masterbranch = rspec.masterbranch
    compatbranch = rspec.compatbranch

    gitcmd = create_git_cmd(rspec.gitconfig)
    @debug "Git command: $gitcmd"

    with_tempdir() do _
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

        if sub_dir === nothing
            rs, msg = update_tomls!(pwd(); kwargs...)
        else
            rs, msg = update_tomls_from_sub_dir!(pwd(), sub_dir; kwargs...)
        end

        for r in rs
            r.project_file !== nothing && safe_git_add(gitcmd, r.project_file)
            commit_manifest && r.manifest_file !== nothing && safe_git_add(gitcmd, r.manifest_file)
        end

        if success(`$gitcmd diff-index --quiet --cached HEAD --`)
            @info "No changes"
        else
            title = "New compat entries"
            body = string(msg)

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
        end

        return rs
    end
end

function safe_git_add(gitcmd, path)
    if success(`$gitcmd check-ignore $path`)
        # path is in .gitignore
        @warn "$path is ignored by git. Skipping."
    else
        run(`$gitcmd add $path`)
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

function format_message(rs::Pair{<:Union{AbstractString,Nothing},CompatResult}...)
    msg = []
    for (i, (name, r)) in enumerate(rs)
        header = name === nothing ? "Summary" : "Summary ($name)"
        push!(msg, Header(header, 3))

        misc = List()
        r.manifest_file !== nothing && push!(misc.items, Paragraph("Updated Manifest"))
        if r.julia_compat !== nothing
            push!(misc.items, Paragraph("Updated compat entry for Julia: v$(r.julia_compat)"))
        end
        push!(misc.items, Paragraph("$(length(r.new)) new compat entries"))
        push!(misc.items, Paragraph("$(length(r.updated)) updated compat entries"))
        push!(misc.items, Paragraph("$(length(r.unchanged)) unchanged compat entries"))
        push!(msg, misc)

        if !isempty(r.new)
            push!(msg, Header("New Compat Entries", 4))
            titles = map(Bold, ["Package", "New Compat"])
            table = Markdown.Table([titles], [:l, :c])
            for (name, new) in r.new
                push!(table.rows, [name, new])
            end
            push!(msg, table)
        end

        if !isempty(r.updated)
            push!(msg, Header("Updated Compat Entries", 4))
            titles = map(Bold, ["Package", "Old Compat", "New Compat"])
            table = Markdown.Table([titles], [:l, :c, :c])
            for (name, old, new) in r.updated
                push!(table.rows, [name, old, new])
            end
            push!(msg, table)
        end
        i != length(rs) && push!(msg, Paragraph()) # line break
    end

    # magic bytes for identifying if an existing PR came from LyceumDevTools.Compat
    push!(msg, HorizontalRule())
    push!(msg, Paragraph("Last updated: $(now())"))
    push!(msg, Paragraph("Magic Bytes: $COMPAT_UUID"))

    Markdown.MD(msg...)
end

end # module
