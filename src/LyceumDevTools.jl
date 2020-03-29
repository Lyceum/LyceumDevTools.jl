module LyceumDevTools

using Base: UUID
using Base64

using GitHub: GitHub, GitHubAPI, Repo, AnonymousAuth, Authorization
using GitHub: authenticate_headers!, authenticate, github2json, api_uri

using HTTP: HTTP
using JuliaFormatter: format_file, format
using LibGit2: LibGit2

using Pkg
using Pkg.Types: projectfile_path, read_project, write_project
using Pkg.Types: manifestfile_path, read_manifest, write_manifest

using PkgTemplates: Template, generate
using Registrator: Registrator
using RegistryTools: register
using Reexport: @reexport


include("configs.jl")

export treehash, repository_dispatch
include("git.jl")

export ly_format_file, ly_format
export with_tempdir, genkeys, with_sandbox_env, cpinto, flattendir
include("misc.jl")

export ly_generate, ly_register, incversion!
include("packaging.jl")

include("Compat.jl")
@reexport using .Compat

include("TestUtil/TestUtil.jl")
@reexport using .TestUtil

end # module
