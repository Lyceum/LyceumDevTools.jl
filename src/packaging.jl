function ly_generate(pkgname::String; kwargs...)
    preset = deepcopy(LY_PKGTEMPLATE)
    push!(preset.authors, "The Contributors of $pkgname")
    t = Template(; preset..., kwargs...)
    generate(pkgname, t)
end

function ly_register(
    package_repo::AbstractString,
    commit::AbstractString,
    lyceumbot_pat::AbstractString;
    push::Bool = true,
    branch::AbstractString = "master",
    kwargs...,
)
    try
        Base.SHA1(commit)
    catch e
        throw(ArgumentError("\"$commit\" is not a valid SHA-1"))
    end

    package_repo = githttpsurl(package_repo) # always register https url

    with_tempdir() do
        git = create_git_cmd(LY_GITCONFIG)

        run(`$git clone $package_repo $(pwd())`)
        run(`$git checkout master`)
        if !success(`$git merge-base --is-ancestor $commit HEAD`)
            error("$commit not found in master branch")
        end
        run(`$git checkout $commit`)

        pkg = Pkg.Types.read_project(projectfile_path(pwd()))
        registry_deps = map(reg -> reg.url, Pkg.Types.collect_registries())

        LY_REGISTRY.url in registry_deps || error("Please add LyceumRegistry: $LY_REGISTRY")

        rbrn = register(
            package_repo,
            pkg,
            string(treehash(pwd()));
            registry = LY_REGISTRY.url,
            registry_deps = registry_deps,
            gitconfig = LY_GITCONFIG,
            push = push,
            branch = branch,
            kwargs...,
        )

        haskey(rbrn.metadata, "error") && error(rbrn.metadata["error"])

        return rbrn
    end
end


function incversion!(pkg::Union{Module,AbstractString}, which::Symbol; prerelease::Symbol = :keep)
    pkg = pkg isa Module ? pkgdir(pkg) : pkg
    isdirty(pkg) && error("$pkg is dirty")

    projectfile = projectfile_path(pkg)
    project = read_project(projectfile)
    project.version = incversion(project.version, which, prerelease = prerelease)
    write_project(project, projectfile)

    git = create_git_cmd(LY_GITCONFIG, path = pkg)
    message = "New version: v$(project.version)"
    run(`$git add Project.toml`)
    run(`$git commit -qm $message`)

    return nothing
end

function incversion(version::Union{String,VersionNumber}, which::Symbol; prerelease = :keep)
    v = version isa String ? VersionNumber(version) : version
    major = v.major
    minor = v.minor
    patch = v.patch
    pre = v.prerelease
    build = v.build

    build != () && @warn "Build not empty: $build"

    if which === :major
        major += 1
        minor = 0
        patch = 0
    elseif which === :minor
        minor += 1
        patch = 0
    elseif which === :patch
        patch += 1
    else
        error("which must be :major, :minor, or :patch. Got $which")
    end

    if prerelease === :keep
        nothing
    elseif prerelease === :dev
        pre = ("DEV",)
    elseif isnothing(prerelease)
        pre = ()
    else
        error("prerelease must be one of :keep, :dev, or nothing")
    end

    vnew = VersionNumber(major, minor, patch, pre, build)
    @info "Old version: $v. New version: $vnew"

    return vnew
end
