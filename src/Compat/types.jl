Base.@kwdef struct RepoSpec
    reponame::String # e.g "Lyceum/LyceumBase.jl"
    username::String
    token::String
    masterbranch::String = MASTER_BRANCH
    compatbranch::String = COMPAT_BRANCH
    gitconfig::Dict{String,String} = Dict{String,String}()
end


MaybeStr = Union{String,Nothing}
Base.@kwdef mutable struct CompatResult
    project_file::String
    # (name, new_compat)
    new::Vector{Tuple{String,String}} = Vector{Tuple{String,String}}()
    # (name, old_compat, new_compat)
    updated::Vector{Tuple{String,String,MaybeStr}} = Vector{Tuple{String,String,MaybeStr}}()
    # (name, old_compat)
    unchanged::Vector{Tuple{String,MaybeStr}} = Vector{Tuple{String,MaybeStr}}()
    julia_compat::MaybeStr = nothing
    manifest_updated::Bool = false
end

function project_updated(r::CompatResult)
    !isempty(r.new) || !isempty(r.updated) || r.julia_compat !== nothing
end
manifest_updated(r::CompatResult) = r.manifest_updated
updated(r::CompatResult) = project_updated(r) || manifest_updated(r)

function format_message(pkg_dir::AbstractString, rs::AbstractVector{CompatResult})
    msg = []
    for (i, r) in enumerate(rs)
        header = "Summary ($(relpath(r.project_file, pkg_dir)))"
        push!(msg, Header(header, 3))

        misc = List()
        r.manifest_updated && push!(misc.items, Paragraph("Updated Manifest"))
        if r.julia_compat !== nothing
            push!(misc.items, Paragraph("Updated compat entry for Julia: v$(r.julia_compat)"))
        end
        push!(misc.items, Paragraph("$(length(r.new)) new compat entries"))
        push!(misc.items, Paragraph("$(length(r.updated)) updated compat entries"))
        push!(misc.items, Paragraph("$(length(r.unchanged)) unchanged compat entries"))
        push!(msg, misc)

        if !isempty(r.new)
            push!(msg, Header("New Compat Entries", 4))
            titles = map(Bold, ["Package", "New Compat"])
            table = Markdown.Table([titles], [:l, :c])
            for (name, new) in r.new
                push!(table.rows, [name, new])
            end
            push!(msg, table)
        end

        if !isempty(r.updated)
            push!(msg, Header("Updated Compat Entries", 4))
            titles = map(Bold, ["Package", "Old Compat", "New Compat"])
            table = Markdown.Table([titles], [:l, :c, :c])
            for (name, old, new) in r.updated
                push!(table.rows, [name, old, new])
            end
            push!(msg, table)
        end
        i != length(rs) && push!(msg, Paragraph()) # line break
    end

    # magic bytes for identifying if an existing PR came from LyceumDevTools.Compat
    push!(msg, HorizontalRule())
    push!(msg, Paragraph("Last updated: $(now(UTC)) UTC"))
    push!(msg, Paragraph("Magic Bytes: $COMPAT_UUID"))

    Markdown.MD(msg...)
end
