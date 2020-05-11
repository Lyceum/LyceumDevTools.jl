module Compat

using ..LyceumDevTools: gitauthurl, create_git_cmd
using ..LyceumDevTools: with_tempdir, issubpath

using GitHub: Repo, Authorization, PullRequest, Branch
using GitHub: repo, authenticate, create_pull_request, edit_issue, pull_requests

using Dates
using Markdown: Markdown, Paragraph, Bold, Table, List, Header, HorizontalRule

using Pkg
using Pkg: Types, Operations
using Pkg.Types: Types, PackageEntry, PackageSpec, VersionSpec, VersionBound, semver_spec
using Pkg.Types: Context, EnvCache, read_package, write_env
using Pkg.Types: Project, projectfile_path, read_project, write_project
using Pkg.Types: Manifest, manifestfile_path, read_manifest, write_manifest

using UUIDs
using UnPack


export RepoSpec, update_tomls!, update_tomls_from_sub_dir!, ghactions


# "magic bytes" embedded in pull requests to identify if a preexisiting PR
const COMPAT_UUID = "0062fa4e-0639-437d-8ed2-9da17d9c0af2"
# For TagBot
const PR_LABELS = ["compat", "nochangelog"]

@static if VERSION < v"1.4"
    const BASE_PACKAGES = Set{Base.UUID}(x for x in keys(Types.stdlib()))
else
    const BASE_PACKAGES = Set{Base.UUID}(x for x in keys(Types.stdlibs()))
end

const MASTER_BRANCH = "master"
const COMPAT_BRANCH = "compat"
const KEEP_OLD_COMPAT = true
const DROP_PATCH = true
const UPDATE_JULIA_COMPAT = false
const UPDATE_MANIFEST = true


include("types.jl")
include("ci.jl")
include("util.jl")
include("update.jl")


function update_tomls!(
    env_dir::AbstractString;
    keep_old_compat::Bool = KEEP_OLD_COMPAT,
    drop_patch::Bool = DROP_PATCH,
    update_julia_compat::Bool = UPDATE_JULIA_COMPAT,
    update_manifest::Bool = UPDATE_MANIFEST,
)
    @info "Resolving project"
    ctx = Context(env = EnvCache(realpath(projectfile_path(env_dir))))
    Pkg.resolve(ctx)

    # only update the registry once
    @info "Updating registries"
    Pkg.Registry.update()
    pkgs = get_updated_versions(ctx)

    result = CompatResult(project_file = ctx.env.project_file)
    _update_compat!(ctx, result, pkgs, keep_old_compat, drop_patch, update_julia_compat)
    update_manifest && _update_manifest!(ctx, result)

    results = [result]
    msg = format_message(env_dir, results)
    println()
    display(msg)
end

function update_tomls_from_test!(
    pkg_dir::AbstractString;
    keep_old_compat::Bool = KEEP_OLD_COMPAT,
    drop_patch::Bool = DROP_PATCH,
    update_julia_compat::Bool = UPDATE_JULIA_COMPAT,
    update_manifest::Bool = UPDATE_MANIFEST,
    remove_redundant::Bool = true,
)
    pkg_ctx = Context(env = EnvCache(realpath(projectfile_path(pkg_dir))))
    @assert Pkg.project(pkg_ctx).ispackage

    @info "Resolving test project"
    test_ctx = Context(env = EnvCache(realpath(projectfile_path(joinpath(pkg_dir, "test")))))
    Pkg.resolve(test_ctx)

    # only update the registry once
    @info "Updating registries"
    Pkg.Registry.update()
    pkgs = get_updated_versions_from_test(pkg_ctx, test_ctx)


    pkg_result = CompatResult(project_file = pkg_ctx.env.project_file)
    _update_compat!(pkg_ctx, pkg_result, pkgs, keep_old_compat, drop_patch, update_julia_compat)

    test_result = CompatResult(project_file = test_ctx.env.project_file)
    if remove_redundant
        remove = [Pkg.project(pkg_ctx).uuid, collect(values(pkg_ctx.env.project.deps))...]
        _update_compat!(test_ctx, test_result, pkgs, keep_old_compat, drop_patch, update_julia_compat, remove = remove)
    else
        _update_compat!(test_ctx, test_result, pkgs, keep_old_compat, drop_patch, update_julia_compat, remove = remove)
    end
    update_manifest && _update_manifest!(test_ctx, test_result)


    results = [pkg_result, test_result]
    msg = format_message(pkg_dir, results)
    println()
    display(msg)
    return results, msg
end

function _update_manifest!(ctx::Context, result::CompatResult)
    new_manifest = with_sandbox(ctx) do _
        Pkg.update(update_registry = false)
        deepcopy(Context().env.manifest)
    end
    if new_manifest != ctx.env.original_manifest
        write_manifest(new_manifest, ctx.env.manifest_file)
        result.manifest_updated = true
    end
    return result
end

function _update_compat!(
    ctx::Context,
    result::CompatResult,
    pkgs::Dict{UUID,PackageEntry},
    keep_old_compat::Bool,
    drop_patch::Bool,
    update_julia_compat::Bool;
    remove::Vector{UUID} = UUID[],
)
    deps = ctx.env.project.deps
    old_compat = ctx.env.original_project.compat
    new_compat = ctx.env.project.compat
    for (name, uuid) in deps
        (isstdlib(uuid) || isjll(name)) && continue

        ver = pkgs[uuid].version

        if haskey(old_compat, name)
            old_entry = old_compat[name]
            if keep_old_compat
                new_entry = format_compat(old_entry, ver, drop_patch)
            else
                new_entry = format_compat(ver, drop_patch)
            end

            old_spec = semver_spec(old_entry)
            new_spec = semver_spec(new_entry)
            if uuid in remove
                delete!(new_compat, name)
                push!(result.updated, (name, old_entry, nothing))
            elseif lowerbound(new_spec) < lowerbound(old_spec) || new_spec == old_spec
                # Don't update the compat entry if it would result in a downgrade
                # and if the specs are equal, keep the old one (however it was formatted)
                # TODO format entry to canonical/compressed form.
                push!(result.unchanged, (name, old_entry))
            else
                new_compat[name] = new_entry
                push!(result.updated, (name, old_entry, new_entry))
            end
        else
            if uuid in remove
                push!(result.unchanged, (name, nothing))
            else
                new_entry = format_compat(ver, drop_patch)
                new_compat[name] = new_entry
                push!(result.new, (name, new_entry))
            end
        end
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

    project_updated(result) && write_project(ctx.env.project, ctx.env.project_file)
    return result
end


end # module
