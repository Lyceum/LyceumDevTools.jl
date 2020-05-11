function ghactions(; kwargs...)
    username = ENV["COMPAT_USERNAME"]
    spec = RepoSpec(
        reponame = ENV["GITHUB_REPOSITORY"],
        username = username,
        token = ENV["COMPAT_TOKEN"],
        masterbranch = get(ENV, "COMPAT_MASTER_BRANCH", MASTER_BRANCH),
        compatbranch = get(ENV, "COMPAT_COMPAT_BRANCH", COMPAT_BRANCH),
        gitconfig = Dict{String,String}("user.name" => username),
    )
    update_tomls!(spec; kwargs...)
    return nothing
end

function update_tomls!(rspec::RepoSpec; update_from_test::Bool = true, overwrite::Bool = true, kwargs...)
    masterbranch = rspec.masterbranch
    compatbranch = rspec.compatbranch

    gitcmd = create_git_cmd(rspec.gitconfig)
    @debug "Git command: $gitcmd"

    with_tempdir() do _
        auth = authenticate(rspec.token)
        ghrepo = repo(rspec.reponame, auth = auth)

        url = gitauthurl(rspec.username, rspec.token, rspec.reponame)
        run(`$gitcmd clone $url repo`)
        cd("repo")

        run(`$gitcmd checkout $masterbranch`)
        run(`$gitcmd pull`)
        if overwrite
            run(`$gitcmd checkout -B $compatbranch`)
        else
            run(`$gitcmd checkout -b $compatbranch`)
        end

        if update_from_test
            rs, msg = update_tomls_from_test!(pwd(); kwargs...)
        else
            rs, msg = update_tomls!(pwd(), kwargs...)
        end

        for r in rs
            project_updated(r) && safe_git_add(gitcmd, r.project_file)
            manifest_updated(r) && safe_git_add(gitcmd, manifestfile_path(dirname(r.project_file)))
        end

        if success(`$gitcmd diff-index --quiet --cached HEAD --`)
            @info "No changes"
        else
            title = "New compat entries"
            body = string(msg)

            run(`$gitcmd commit -m $title`)
            run(`$gitcmd push --force -u origin $compatbranch`)

            existing_pr = find_existing_pr(ghrepo, auth, compatbranch, masterbranch)
            if existing_pr === nothing
                params = Dict(
                    "title" => title,
                    "body" => body,
                    "labels" => PR_LABELS,
                    "head" => compatbranch,
                    "base" => masterbranch,
                )
                pr = create_pull_request(ghrepo; params = params, auth = auth)
                # NOTE: Adding labels when PR is created doesn't appear to work so
                # we edit it after creation.
                edit_issue(ghrepo, pr, params = Dict("labels" => PR_LABELS), auth = auth)
            else
                params = Dict("title" => title, "body" => body, "labels" => PR_LABELS)
                edit_issue(ghrepo, existing_pr, params = params, auth = auth)
            end
        end

        return rs
    end
end

function safe_git_add(gitcmd, path)
    if success(`$gitcmd check-ignore $path`)
        # path is in .gitignore
        @warn "$path is ignored by git. Skipping."
    else
        run(`$gitcmd add $path`)
    end
end

function find_existing_pr(repo::Repo, auth::Authorization, head::String, base::String)
    params = Dict(
        "state" => "open",
        "head" => "$(repo.owner.login):$head",
        "base" => base,
        "per_page" => 50,
        "page" => 1,
    )
    prs = Vector{PullRequest}()

    page_prs, page_data = pull_requests(repo, params = params, auth = auth)
    while true
        append!(prs, page_prs)
        if haskey(page_data, "next")
            page_prs, page_data = pull_requests(repo, auth = auth, start_page = page_data["next"])
        else
            break
        end
    end

    if isempty(prs)
        @debug "No PR found"
        return nothing
    elseif length(prs) == 1
        pr = first(prs)
        if occursin(COMPAT_UUID, pr.body)
            @info "Found existing PR"
            return pr
        else
            error("PR already exists but it wasn't created by Compat. Aborting.")
        end
    else
        error("More than one compat PR found. This shouldn't happen.")
    end
end
