isstdlib(name::AbstractString) = isstdlib(Base.UUID(name))
isstdlib(uuid::Base.UUID) = uuid in BASE_PACKAGES
isjll(name::AbstractString) = endswith(lowercase(strip(name)), lowercase(strip("_jll"))) # TODO check for Artifacts.toml?

function format_compat(v::VersionNumber, drop_patch::Bool)
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

function bound2ver(bound::VersionBound)
    bound.n == 0 && error("bound.n must be > 0 to convert to VersionNumber")
    return VersionNumber(bound[1], bound[2], bound[3])
end
