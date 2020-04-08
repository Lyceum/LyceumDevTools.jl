function ly_format_file(path::AbstractString; kwargs...)
    format_file(path; LY_JULIAFORMATTER..., kwargs...)
end
ly_format(paths...; kwargs...) = format(paths...; LY_JULIAFORMATTER..., kwargs...)
ly_format(pkgs::Module...; kwargs...) = ly_format(map(pkgdir, pkgs)...; kwargs...)

with_tempdir(f) = mktempdir(dir -> cd(() -> f(dir), dir))

# copied from Documenter.jl
function genkeys(; user = "\$USER", repo = "\$REPO", comment = "lyceumdevs@gmail.com")
    # Error checking. Do the required programs exist?
    success(`which which`) || error("'which' not found.")
    success(`which ssh-keygen`) || error("'ssh-keygen' not found.")

    directory = pwd()
    filename = tempname()

    isfile(filename) && error("temporary file '$(filename)' already exists in working directory")
    isfile("$(filename).pub") &&
    error("temporary file '$(filename).pub' already exists in working directory")

    # Generate the ssh key pair.
    success(`ssh-keygen -N "" -C $comment -f $filename`) ||
    error("failed to generate a SSH key pair.")

    # Prompt user to add public key to github then remove the public key.
    let url = "https://github.com/$user/$repo/settings/keys"
        @info("add the public key below to $url with read/write access:")
        println("\n", read("$filename.pub", String))
        rm("$filename.pub")
    end

    # Base64 encode the private key and prompt user to add it to travis. The key is
    # *not* encoded for the sake of security, but instead to make it easier to
    # copy/paste it over to travis without having to worry about whitespace.
    let travis_url = "https://travis-ci.com/$user/$repo/settings",
        github_url = "https://github.com/$user/$repo/settings/secrets"

        @info(
            "add a secure environment variable named to " *
            "$(travis_url) (if you deploy using Travis CI) or " *
            "$(github_url) (if you deploy using GitHub Actions) with value:"
        )
        println("\n", base64encode(read(filename, String)), "\n")
        rm(filename)
    end
end

hasmanifest(pkgdir::AbstractString) = manifestfile_path(pkgdir, strict = true) !== nothing
hasproject(pkgdir::AbstractString) = projectfile_path(pkgdir, strict = true) !== nothing

function with_sandbox_env(
    fn::Function,
    project::AbstractString = Base.active_project();
    copyall::Bool = false,
    extra_load_paths::Vector{<:AbstractString} = AbstractString[],
    default_load_path::Bool = false,
)
    if isdir(project)
        project = projectfile_path(project, strict = true)
        isnothing(project) && error("No project file found in $project")
    end

    old_dir = pwd()
    old_load_path = deepcopy(LOAD_PATH)
    old_project = Base.active_project()

    mktempdir() do sandbox
        if copyall
            cpinto(dirname(project), sandbox)
        else
            manifest = manifestfile_path(dirname(project), strict = true)
            manifest !== nothing && cp(manifest, joinpath(sandbox, basename(manifest)))
            cp(project, joinpath(sandbox, basename(project)))
        end

        try
            cd(sandbox)
            if default_load_path
                empty!(LOAD_PATH)
                Base.init_load_path()
            end
            Pkg.activate(pwd())
            append!(LOAD_PATH, map(normpath, extra_load_paths))
            return fn()
        finally
            cd(old_dir)
            append!(empty!(LOAD_PATH), old_load_path)
            Pkg.activate(old_project)
        end
    end
end

function cpinto(srcdir::AbstractString, dstdir::AbstractString)
    isdir(srcdir) || throw(ArgumentError("Expected a directory for `srcdir`, got $srcdir"))
    isdir(dstdir) || throw(ArgumentError("Expected a directory for `dstdir`, got $dstdir"))
    for file_or_dir in readdir(srcdir)
        cp(joinpath(srcdir, file_or_dir), joinpath(dstdir, file_or_dir))
    end
end

function flattendir(
    dir::AbstractString = pwd();
    join::Bool = false,
    sort::Bool = true,
    dirs::Bool = true,
    files::Bool = true,
)
    paths = String[]
    for (root, _dirs, _files) in walkdir(dir)
        if dirs
            for dir in _dirs
                push!(paths, joinpath(root, dir))
            end
        end
        if files
            for file in _files
                push!(paths, joinpath(root, file))
            end
        end
    end
    !join && (paths = map(path -> relpath(path, dir), paths))
    sort && sort!(paths)
    return paths
end
