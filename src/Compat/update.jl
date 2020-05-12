function get_updated_versions_from_test(pkg_ctx::Context, test_ctx::Context)
    pkg_project = deepcopy(pkg_ctx.env.project)
    test_project = deepcopy(test_ctx.env.project)
    test_manifest = deepcopy(test_ctx.env.manifest)
    # abspath! to maintain location of all deved nodes except package
    abspath!(test_ctx, test_manifest)

    lowerbound!(pkg_project)
    lowerbound!(test_project)

    updated_versions = Dict{UUID,VersionNumber}()
    mktempdir() do tmp_pkg_dir
        # dummy project
        tmp_test_dir = mkdir(joinpath(tmp_pkg_dir, "test"))
        mkdir(joinpath(tmp_pkg_dir, "src"))
        touch(joinpath(tmp_pkg_dir, "src/$(pkg_project.name).jl"))

        write_project(pkg_project, projectfile_path(tmp_pkg_dir))
        write_project(test_project, projectfile_path(tmp_test_dir))
        write_manifest(test_manifest, manifestfile_path(tmp_test_dir))
        with_temp_env(tmp_test_dir) do
            # point sandbox_manifest to look for the project in tmp_pkg_dir
            Pkg.develop(PackageSpec(uuid=pkg_project.uuid, path=".."))
            Pkg.update(update_registry = false)
            for (uuid, entry) in Context().env.manifest
                if entry.version !== nothing
                    updated_versions[uuid] = entry.version
                end
            end
        end
    end

    return updated_versions
end

function get_updated_versions(ctx::Context)
    project = deepcopy(ctx.env.project)
    lowerbound!(project)

    updated_versions = Dict{UUID,VersionNumber}()
    with_sandbox(ctx) do tmp
        write_project(project, projectfile_path(tmp))
        Pkg.update(update_registry = false)
        for (uuid, entry) in Context().env.manifest
            if entry.version !== nothing
                updated_versions[uuid] = entry.version
            end
        end
    end

    return updated_versions
end

# Prevent downgrading any deps below the lower bound of their current compat entry
# by replacing each compat entry with an inequality specifier
# e.g "0.2.1, 0.3, 0.5" --> ">= 0.2.1"
function lowerbound!(project::Project)
    for (name::String, uuid::UUID) in project.deps
        if haskey(project.compat, name)
            project.compat[name] = format_lowerbound_compat(semver_spec(project.compat[name]))
        end
    end
    return project
end
