module LyceumDevTools

using Base: UUID
using Base64
using Pkg
using LibGit2: LibGit2

using Registrator: Registrator
using JuliaFormatter: format_file, format
using RegistryTools: register
using PkgTemplates: Template, generate
using GitHub: GitHub, authenticate_headers!, AnonymousAuth, github2json, api_uri, GitHubAPI
using HTTP: HTTP


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
