isstdlib(name::AbstractString) = isstdlib(Base.UUID(name))
isstdlib(uuid::Base.UUID) = uuid in BASE_PACKAGES
isjll(name::AbstractString) = endswith(lowercase(strip(name)), lowercase(strip("_jll"))) # TODO check for Artifacts.toml?


function format_compat(v::VersionNumber, drop_patch::Bool=false)
    isempty(v.prerelease) || @warn "Ignoring prerelease suffix"
    isempty(v.build) || @warn "Ignoring build suffix"
    if v.patch == 0 || drop_patch
        if v.minor == 0
            return "$(v.major)"
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
        return format_compat(VersionNumber(compat), drop_patch)
    catch
        try
            spec = VersionSpec(semver_spec(compat)) # check to make sure valid
            @assert spec isa VersionSpec
            return String(strip(compat))
        catch
            throw(ArgumentError("not a valid compat entry: $compat"))
        end
    end
end

function format_compat(old, new, drop_patch)
    "$(format_compat(old, drop_patch)), $(format_compat(new, drop_patch))"
end

lowerbound(spec::VersionSpec) = minimum(r -> bound2ver(r.lower), spec.ranges)

format_lowerbound_compat(spec::VersionSpec) = ">= $(format_compat(lowerbound(spec)))"

bound2ver(bound::VersionBound) = VersionNumber(bound[1], bound[2], bound[3])

function with_sandbox(fn::Function, ctx::Context)
    project = deepcopy(ctx.env.project)
    manifest = deepcopy(ctx.env.manifest)
    Operations.abspath!(ctx, manifest)
    mktempdir() do tmp
        write_project(project, projectfile_path(tmp))
        write_manifest(manifest, manifestfile_path(tmp))
        Operations.with_temp_env(tmp) do
            Pkg.resolve()
            return fn(tmp)
        end
    end
end
