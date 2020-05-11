function get_updated_versions_from_test(pkg_ctx::Context, test_ctx::Context)
    pkg_project = deepcopy(pkg_ctx.env.project)
    test_project = deepcopy(test_ctx.env.project)
    test_manifest = deepcopy(test_ctx.env.manifest)
    # abspath! to maintain location of all deved nodes except package
    Operations.abspath!(test_ctx, test_manifest)

    # Prevent downgrading any deps below the lower bound of their current compat entry
    # by replacing each compat entry with an inequality specifier
    # e.g "0.2.1, 0.3, 0.5" --> ">= 0.2.1"
    for (uuid::UUID, entry::PackageEntry) in test_manifest
        name = entry.name
        (isstdlib(uuid) || isjll(name)) && continue
        pkg_spec = semver_spec(get(pkg_project.compat, name, ">= 0"))
        test_spec = semver_spec(get(test_project.compat, name, ">= 0"))
        lb = format_lowerbound_compat(union(pkg_spec, test_spec))
        if haskey(pkg_project.compat, name)
            pkg_project.compat[name] = lb
        end
        if haskey(test_project.compat, name)
            test_project.compat[name] = lb
        end
    end

    updated_versions = Dict{UUID,Types.PackageEntry}()
    mktempdir() do tmp_pkg_dir
        # dummy project
        tmp_test_dir = mkdir(joinpath(tmp_pkg_dir, "test"))
        mkdir(joinpath(tmp_pkg_dir, "src"))
        touch(joinpath(tmp_pkg_dir, "src/$(pkg_project.name).jl"))

        # point sandbox_manifest to look for the project in tmp_pkg_dir
        test_manifest[pkg_project.uuid].path = tmp_pkg_dir

        write_project(pkg_project, projectfile_path(tmp_pkg_dir))
        write_project(test_project, projectfile_path(tmp_test_dir))
        write_manifest(test_manifest, manifestfile_path(tmp_test_dir))

        Operations.with_temp_env(tmp_test_dir) do
            Pkg.update(update_registry = false)
            for (uuid, entry) in Context().env.manifest
                updated_versions[uuid] = entry
            end
        end
    end

    return updated_versions
end

function get_updated_versions(ctx::Context)
    project = deepcopy(ctx.env.project)
    # see note above similar block in get_updated_versions_from_test
    for (name::String, uuid::UUID) in project.deps
        if haskey(project.compat, name)
            lb = format_lowerbound_compat(semver_spec(project.compat[name]))
            project.compat[name] = lb
        end
    end

    updated_versions = Dict{UUID,PackageEntry}()
    with_sandbox(ctx) do tmp
        write_project(project, projectfile_path(tmp))
        Pkg.update(update_registry = false)
        for (uuid, entry) in Context().env.manifest
            updated_versions[uuid] = entry
        end
    end

    return updated_versions
end
