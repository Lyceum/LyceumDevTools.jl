const LY_JULIAFORMATTER = (
    overwrite = true,
    indent = 4,
    margin = 100,
    always_for_in = false,
    whitespace_typedefs = false,
    whitespace_ops_in_indices = false,
    remove_extra_newlines = false,
)

const LY_PKGTEMPLATE = (
    user = "Lyceum",
    host = "github.com",
    license = "MIT",
    authors = ["Colin Summers"],
    ssh = true,
    manifest = true,
    julia_version = VERSION,
    dev = false,
)

const LY_GITCONFIG = Dict("user.name" => "lyceum", "user.email" => "lyceumdevs@gmail.com")

const LY_REGISTRY = RegistrySpec(
    uuid = "96ca1a0e-015d-46b7-a12d-07d1320642ca",
    name = "LyceumRegistry",
    url = "https://github.com/Lyceum/LyceumRegistry.git",
)

const GENERAL_REGISTRY = RegistrySpec(
    uuid = "23338594-aafe-5451-b93e-139f81909106",
    name = "General",
    url = "https://github.com/JuliaRegistries/General.git",
)
