module Compat

using ..LyceumDevTools: gitauthurl, create_git_cmd
using ..LyceumDevTools: with_tempdir, issubpath

using GitHub: Repo, Authorization, PullRequest, Branch
using GitHub: repo, authenticate, create_pull_request, edit_issue, pull_requests

using Dates
using Markdown: Markdown, Paragraph, Bold, Table, List, Header, HorizontalRule

using Pkg
using Pkg.Types: PackageEntry, PackageSpec, VersionSpec, VersionBound, semver_spec, is_stdlib
using Pkg.Types: Context, EnvCache, write_env, manifest_info
using Pkg.Types: Project, projectfile_path, read_package, read_project, write_project
using Pkg.Types: Manifest, manifestfile_path, read_manifest, write_manifest
using Pkg.Operations: abspath!, with_temp_env

using UUIDs
using UnPack


export RepoSpec, update_tomls!, update_tomls_from_test!, ghactions


# "magic bytes" embedded in pull requests to identify if a preexisiting PR
const COMPAT_UUID = "0062fa4e-0639-437d-8ed2-9da17d9c0af2"
# For TagBot
const PR_LABELS = ["compat", "nochangelog"]

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
    # only update the registry once
    @info "Updating registries"
    Pkg.Registry.update()

    @info "Resolving project"
    ctx = Context(env = EnvCache(realpath(projectfile_path(env_dir))))
    Pkg.instantiate(ctx)
    Pkg.resolve(ctx)

    vers = get_updated_versions(ctx)

    result = CompatResult(project_file = ctx.env.project_file)
    _update_compat!(ctx, result, vers, keep_old_compat, drop_patch, update_julia_compat)
    #&& write_project(ctx.env.project, ctx.env.project_file)
    update_manifest && _update_manifest!(ctx, result)

    # Sanity check: the versions one would get after a Pkg.update() match those used to generate
    # the compat entries.
    with_sandbox(ctx) do tmp
        Pkg.update(update_registry = false)
        _check_versions(Context().env.manifest, vers)
    end

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
    # only update the registry once
    @info "Updating registries"
    Pkg.Registry.update()

    pkg_ctx = Context(env = EnvCache(realpath(projectfile_path(pkg_dir))))
    pkg_info = Pkg.project(pkg_ctx)
    pkg_info.ispackage || error("Not a package: $pkg_dir")

    @info "Resolving test project"
    test_ctx = Context(env = EnvCache(realpath(projectfile_path(joinpath(pkg_dir, "test")))))
    Pkg.instantiate(test_ctx)
    Pkg.resolve(test_ctx)
    #was_deved = test_ctx.env.manifest TODO

    vers = get_updated_versions_from_test(pkg_ctx, test_ctx)


    pkg_result = CompatResult(project_file = pkg_ctx.env.project_file)
    _update_compat!(pkg_ctx, pkg_result, vers, keep_old_compat, drop_patch, update_julia_compat)
    write_project(pkg_ctx.env.project, pkg_ctx.env.project_file)

    test_result = CompatResult(project_file = test_ctx.env.project_file)
    remove = remove_redundant ? [pkg_info.uuid, values(pkg_ctx.env.project.deps)...] : UUID[]
    _update_compat!(test_ctx, test_result, vers, keep_old_compat, drop_patch, update_julia_compat, remove = remove)
    write_project(test_ctx.env.project, test_ctx.env.project_file)
    # TODO resolve
    if update_manifest
        Pkg.update(test_ctx, update_registry = false)
        test_result.manifest_updated = test_ctx.env.manifest != test_ctx.env.original_manifest
    end

    # Sanity check: the versions one would get after a Pkg.update() match those used to generate
    # the compat entries.
    with_sandbox(test_ctx) do tmp
        Pkg.develop(PackageSpec(uuid=pkg_info.uuid, path=pkg_ctx.env.manifest_file))
        Pkg.update(update_registry = false)
        _check_versions(Context().env.manifest, vers)
    end

    results = [pkg_result, test_result]
    msg = format_message(pkg_dir, results)
    println()
    display(msg)
    return results, msg
end

function _check_versions(man::Manifest, vers::Dict{UUID,VersionNumber})
    for (uuid, entry) in man
        if haskey(vers, uuid) && entry.version != vers[uuid]
            vpre, vpost = vers[uuid], entry.version
            error("Version mismatch after compat update for $(entry.name): $vpre != $vpost")
        end
    end
end

function _update_compat!(
    ctx::Context,
    result::CompatResult,
    vers::Dict{UUID,VersionNumber},
    keep_old_compat::Bool,
    drop_patch::Bool,
    update_julia_compat::Bool;
    remove::Vector{UUID} = UUID[],
)
    deps = ctx.env.project.deps
    old_compat = ctx.env.original_project.compat
    new_compat = ctx.env.project.compat
    for (name, uuid) in deps
        (is_stdlib(uuid) || isjll(name) || !haskey(vers, uuid)) && continue

        ver = vers[uuid]

        if haskey(old_compat, name)
            old_entry = old_compat[name]
            if uuid in remove
                delete!(new_compat, name)
                push!(result.updated, (name, old_entry, nothing))
                continue
            end

            if keep_old_compat
                new_entry = format_compat(old_entry, ver, drop_patch)
            else
                new_entry = format_compat(ver, drop_patch)
            end

            old_spec = semver_spec(old_entry)
            new_spec = semver_spec(new_entry)
            if lowerbound(new_spec) < lowerbound(old_spec) || new_spec == old_spec
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

    if update_julia_compat
        new_compat["julia"] = format_compat(VERSION, drop_patch)
        if new_compat["julia"] != get(old_compat, "julia", nothing)
            result.julia_compat = new_compat["julia"]
        end
    end

    project_updated(result)

    return result
end


end # module
