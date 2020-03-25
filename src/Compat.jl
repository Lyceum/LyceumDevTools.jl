module Compat

using ..LyceumDevTools: gitauthurl, create_git_cmd
using ..LyceumDevTools: with_tempdir, with_sandbox_env, parsetomls

using Dates
using GitHub: Repo, Authorization, PullRequest
using GitHub: repo, authenticate, create_pull_request, edit_issue, pull_requests
using Markdown: Markdown, Paragraph, Bold, Table, List, Header, HorizontalRule
using Parameters
using Pkg
using Pkg.Types: VersionSpec, semver_spec


const BASE_PACKAGES = Set{Base.UUID}(x for x in keys(Pkg.Types.stdlibs()))
const COMPAT_UUID = "0062fa4e-0639-437d-8ed2-9da17d9c0af2"

const DEFAULT_MASTERBRANCH = "master"
const DEFAULT_COMPATBRANCH = "compat"

const DEF_KEEP_OLD_COMPAT = true
const DEF_UPDATE_MANIFEST = true
const DEF_DROP_PATCH = true
const DEF_ADD_JULIA_COMPAT = true

const COMPAT_LABELS = ["compat", "nochangelog"]


Base.@kwdef struct RepoSpec
    token::String
    username::String
    useremail::String
    reponame::String
    masterbranch::String
    compatbranch::String
end

mutable struct CompatResult
    manifest_updated::Bool
    new_compat_section::Bool
    new_julia_compat::Union{String,Nothing}
    multiple_entries::Vector{Tuple{String,Vector{String}}} # (name, UUIDs)
    bad_version::Vector{Tuple{String,String}} # (name, version)
    new::Vector{Tuple{String,String}} # (name, new_compat)
    changed::Vector{Tuple{String,String,String}} # (name, old_compat, new_compat)
    unchanged::Vector{Tuple{String,String}} # (name, old_compat)
    function CompatResult()
        new(
            false,
            false,
            nothing,
            Vector{Tuple{String,Vector{String}}}(),
            Vector{Tuple{String,String}}(),
            Vector{Tuple{String,String}}(),
            Vector{Tuple{String,String,String}}(),
            Vector{Tuple{String,String}}(),
        )
    end
end


function ghactions(; kwargs...)
    spec = RepoSpec(
        token = ENV["COMPAT_TOKEN"],
        username = ENV["COMPAT_USERNAME"],
        useremail = ENV["COMPAT_USEREMAIL"],
        reponame = ENV["GITHUB_REPOSITORY"],
        masterbranch = get(ENV, "COMPAT_MASTERBRANCH", DEFAULT_MASTERBRANCH),
        compatbranch = get(ENV, "COMPAT_COMPATBRANCH", DEFAULT_COMPATBRANCH),
    )
    return update_tomls!(spec; kwargs...)
end

function update_tomls!(
    rspec::RepoSpec;
    keep_old_compat::Bool = DEF_KEEP_OLD_COMPAT,
    update_manifest::Bool = DEF_UPDATE_MANIFEST,
    drop_patch::Bool = DEF_DROP_PATCH,
    add_julia_compat::Bool = DEF_ADD_JULIA_COMPAT,
    dry_run::Bool = false,
)
    masterbranch = rspec.masterbranch
    compatbranch = rspec.compatbranch

    gitcmd = create_git_cmd("user.name" => rspec.username, "user.email" => rspec.useremail)
    @debug "Git command: $gitcmd"

    with_tempdir() do
        auth = authenticate(rspec.token)
        ghrepo = repo(rspec.reponame, auth = auth)

        url = gitauthurl(rspec.username, rspec.token, rspec.reponame)
        run(`$gitcmd clone $url repo`)
        cd("repo")

        run(`$gitcmd checkout $masterbranch`)
        run(`$gitcmd pull`)
        # overwrite existing compat branch if it exists
        run(`$gitcmd checkout -B $compatbranch`)

        result = update_tomls!(
            pwd(),
            keep_old_compat = keep_old_compat,
            update_manifest = update_manifest,
            drop_patch = drop_patch,
            add_julia_compat = add_julia_compat,
        )

        shouldpush = (
            result.manifest_updated
            || result.new_compat_section
            || result.new_julia_compat !== nothing
            || !isempty(result.multiple_entries)
            || !isempty(result.bad_version)
            || !isempty(result.new)
            || !isempty(result.changed)
        )

        if shouldpush && !dry_run
            project = Pkg.Types.projectfile_path(pwd(), strict = true)
            @debug "Project file: $project"
            run(`$gitcmd add $project`)

            if result.manifest_updated
                manifest = Pkg.Types.manifestfile_path(pwd(), strict = true)
                @debug "Manifest file: $manifest"
                run(`$gitcmd add $manifest`)
            end

            title = "New compat entries"
            body = string(format_message(result))
            run(`$gitcmd commit -m $title`)

            run(`$gitcmd push --force -u origin $compatbranch`)

            params = Dict(
                "title" => title,
                "base" => masterbranch,
                "head" => compatbranch,
                "body" => body,
                "labels" => COMPAT_LABELS,
            )
            existing_pr = find_existing_pr(ghrepo, auth)
            if isnothing(existing_pr)
                pr = create_pull_request(ghrepo; params = params, auth = auth)
                edit_issue(
                    ghrepo,
                    pr,
                    params = Dict("labels" => COMPAT_LABELS),
                    auth = auth,
                )
            else
                params = Dict("body" => body, "labels" => COMPAT_LABELS)
                edit_issue(ghrepo, existing_pr, params = params, auth = auth)
            end
        else
            if dry_run
                @warn "Dry Run"
            else
                @info "No changes."
            end
        end

        return result
    end
end


function update_tomls!(
    pkgdir::AbstractString;
    keep_old_compat::Bool = DEF_KEEP_OLD_COMPAT,
    update_manifest::Bool = DEF_UPDATE_MANIFEST,
    drop_patch::Bool = DEF_DROP_PATCH,
    add_julia_compat::Bool = DEF_ADD_JULIA_COMPAT,
)
    @debug "Compat options" keep_old_compat update_manifest drop_patch add_julia_compat

    result = CompatResult()

    old_tomls = get_old_tomls(pkgdir)
    old_project = old_tomls.project.dict
    old_manifest = old_tomls.manifest.dict

    new_tomls = get_new_tomls(pkgdir)
    new_project = new_tomls.project.dict
    new_manifest = new_tomls.manifest.dict

    for k in keys(old_project)
        if k != "compat" && get(old_project, k, nothing) != get(new_project, k, nothing)
            error("TOML mismatch key $k. Please file a bug report.")
        end
    end

    result.manifest_updated = update_manifest && old_manifest != new_manifest

    if !haskey(old_project, "compat")
        old_project["compat"] = Dict{Any,Any}()
        new_project["compat"] = Dict{Any,Any}()
        result.new_compat_section = true
    end

    if add_julia_compat && !haskey(old_project["compat"], "julia")
        julia_compat = format_compat(VERSION, drop_patch)
        new_project["compat"]["julia"] = julia_compat
        result.new_julia_compat = julia_compat
    end

    for (name, uuid) in pairs(old_project["deps"])
        (isstdlib(uuid) || isjll(name)) && continue

        if length(new_manifest[name]) > 1
            entries = new_manifest[name]
            push!(result.multiple_entries, (name, map(x -> x["uuid"], entries)))
            continue
        end

        new_version = VersionNumber(first(new_manifest[name])["version"])
        if !no_prerelease_or_build(new_version)
            push!(result.bad_version, (name, string(new_version)))
            continue
        end

        if haskey(old_project["compat"], name)
            old_compat = format_compat(old_project["compat"][name], drop_patch)
            if keep_old_compat
                new_compat = format_compat(old_compat, new_version, drop_patch)
            else
                new_compat = format_compat(new_version, drop_patch)
            end

            if semver_spec(old_compat) == semver_spec(new_compat)
                # Same semver spec, but keep old formatting
                # TODO change this to provide a canoncial/compressed compat entry
                new_compat = old_compat
                push!(result.unchanged, (name, old_compat))
            else
                push!(result.changed, (name, old_compat, new_compat))
            end
        else
            new_compat = format_compat(new_version, drop_patch)
            push!(result.new, (name, new_compat))
        end

        new_project["compat"][name] = new_compat
    end

    # Sanity check
    for (name, compat) in pairs(new_project["compat"])
        try
            @assert VersionSpec(semver_spec(compat)) isa VersionSpec
        catch
            error("Invalid compat $compat for $name. Please file a bug report.")
        end
    end

    project_filename = basename(Pkg.Operations.projectfile_path(pkgdir, strict = true))
    open(joinpath(pkgdir, project_filename), "w") do io
        Pkg.TOML.print(
            io,
            new_project,
            sorted = true, # TODO
            by = key -> (Pkg.Types.project_key_order(key), key),
        )
    end

    if update_manifest
        manifestpath = Pkg.Operations.manifestfile_path(pkgdir, strict = true)
        if !isnothing(manifestpath)
            open(joinpath(pkgdir, basename(manifestpath)), "w") do io
                Pkg.TOML.print(io, new_manifest) # TODO sort
            end
        end
    end

    return result
end


function get_old_tomls(pkgdir)
    with_sandbox_env(pkgdir) do
        # Create/resolve manifest if one doesn't already exist,
        Pkg.instantiate()
        Pkg.resolve()
        return parsetomls(pwd())
    end
end

function get_new_tomls(pkgdir::AbstractString)
    with_sandbox_env(pkgdir) do
        purge_compat!(pwd())
        Pkg.instantiate()
        Pkg.resolve()
        Pkg.update()
        return parsetomls(pwd())
    end
end

function purge_compat!(pkgdir::AbstractString)
    cd(pkgdir) do
        tomls = parsetomls(pwd())
        if haskey(tomls.project.dict, "compat")
            for pkg in keys(tomls.project.dict["compat"])
                pkg != "julia" && delete!(tomls.project.dict["compat"], pkg)
            end
        end
        projectpath = Pkg.Operations.projectfile_path(pwd(), strict = true)
        open(projectpath, "w") do io
            Pkg.TOML.print(io, tomls.project.dict)
        end
    end
end

isstdlib(name::AbstractString) = isstdlib(Base.UUID(name))
isstdlib(uuid::Base.UUID) = uuid in BASE_PACKAGES
isjll(name::AbstractString) = endswith(lowercase(strip(name)), lowercase(strip("_jll"))) # TODO check for Artifacts.toml?

no_prerelease_or_build(v::VersionNumber) = v.build == v.prerelease == ()
no_prerelease_or_build(v) = no_prerelease_or_build(VersionNumber(v))

function format_compat(v::VersionNumber, drop_patch::Bool)
    no_prerelease_or_build(v) ||
    throw(ArgumentError("version cannot have build or prerelease. Got: $v"))
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
            spec = Pkg.Types.VersionSpec(Pkg.Types.semver_spec(compat)) # check to make sure valid
            @assert spec isa VersionSpec
            return String(strip(compat))
        catch
            throw(ArgumentError("not a valid compat entry: $compat"))
        end
    end
end

function majorminorequal(x::AbstractString, y::AbstractString)
    x = String(strip(x))
    y = String(strip(y))
    if startswith(x, '^')
        x = String(strip(split(x, '^')[2]))
    end
    if startswith(y, '^')
        y = String(strip(split(y, '^')[2]))
    end
    try
        xver = VersionNumber(x)
        yver = VersionNumber(y)
        return xver.major == yver.major && xver.minor == yver.minor
    catch
        return false
    end
end

function format_compat(old, new, drop_patch)
    "$(format_compat(old, drop_patch)), $(format_compat(new, drop_patch))"
end

function find_existing_pr(repo::Repo, auth::Authorization)
    params = Dict("state" => "open", "per_page" => 100, "page" => 1)
    prs, page_data = pull_requests(repo; auth = auth, params = params, page_limit = 100)
    compat_prs = Vector{PullRequest}()

    while true
        for pr in prs
            occursin(COMPAT_UUID, pr.body) && push!(compat_prs, pr)
        end
        if haskey(page_data, "next")
            prs, page_data = pull_requests(
                repo;
                auth = auth,
                page_limit = 100,
                start_page = page_data["next"],
            )
        else
            break
        end
    end

    if isempty(compat_prs)
        @debug "No PR found"
        return nothing
    elseif length(compat_prs) == 1
        @debug "Found existing PR"
        return first(compat_prs)
    else
        error("More than one compat PR found. This shouldn't happen.")
    end
end

function format_message(r::CompatResult)
    msg = []
    push!(msg, Header("Compat Update", 2))

    misc = List()
    if r.manifest_updated
        push!(misc.items, Paragraph("Updated Manifest"))
    end
    if r.new_compat_section
        push!(misc.items, Paragraph("Added new compat section"))
    end
    if r.new_julia_compat !== nothing
        push!(misc.items, Paragraph("Added compat entry for Julia: v$(r.new_julia_compat)"))
    end
    !isempty(misc.items) && push!(msg, misc)

    if !isempty(r.multiple_entries)
        push!(msg, Header("Skipped (multiple packages with the same name)", 3))
        list = List()
        for (name, uuids) in r.multiple_entries
            #push!(list.items, [Paragraph(name), List(Paragraph.(uuids))])
            push!(list.items, [Paragraph("$name UUIDs:"), List(Paragraph.(uuids))])
        end
        push!(msg, list)
    end
    if !isempty(r.bad_version)
        push!(msg, Header("Skipped (new version has build or prerelease specifier)", 3))
        titles = map(Bold, ["Package", "New Version"])
        table = Markdown.Table([titles], [:l, :c])
        for (name, new) in r.bad_version
            push!(table.rows, [name, new])
        end
        push!(msg, table)
    end
    if !isempty(r.new)
        push!(msg, Header("New", 3))
        titles = map(Bold, ["Package", "New Compat"])
        table = Markdown.Table([titles], [:l, :c])
        for (name, new) in r.new
            push!(table.rows, [name, new])
        end
        push!(msg, table)
    end
    if !isempty(r.changed)
        push!(msg, Header("Updated", 3))
        titles = map(Bold, ["Package", "Old Compat", "New Compat"])
        table = Markdown.Table([titles], [:l, :c, :c])
        for (name, old, new) in r.changed
            push!(table.rows, [name, old, new])
        end
        push!(msg, table)
    end
    push!(msg, HorizontalRule())
    push!(msg, Paragraph(COMPAT_UUID))
    Markdown.MD(msg...)
end

end # module
