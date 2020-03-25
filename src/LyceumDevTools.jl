module LyceumDevTools

using Base: UUID
using Base64
using GitHub: GitHub, GitHubAPI, Repo, AnonymousAuth, Authorization
using GitHub: authenticate_headers!, authenticate, github2json, api_uri
using HTTP: HTTP
using JuliaFormatter: format_file, format
using LibGit2: LibGit2
using Pkg
using Pkg.Types: projectfile_path, manifestfile_path, write_project, write_manifest
using PkgTemplates: Template, generate
using Registrator: Registrator
using RegistryTools: register


include("configs.jl")

export treehash, repository_dispatch
include("git.jl")

export ly_format_file, ly_format
export with_tempdir, genkeys, parsetomls, with_sandbox_env, cpinto, envinfo
include("misc.jl")

export lygenerate, lyregister, incversion!
include("packaging.jl")

export Compat
include("Compat.jl")

end # module
