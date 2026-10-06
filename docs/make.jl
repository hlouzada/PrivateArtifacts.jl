using Documenter
using PrivateArtifacts

makedocs(;
    sitename = "PrivateArtifacts.jl",
    modules = [PrivateArtifacts],
    format = Documenter.HTML(;
        canonical = "https://hlouzada.github.io/PrivateArtifacts.jl",
        edit_link = "main",
    ),
    pages = [
        "Home" => "index.md",
        "Private Download entries" => "artifacts.md",
        "Authentication" => "authentication.md",
        "Source Kinds" => "sources.md",
        "Hash Behavior" => "hashes.md",
        "API Reference" => "api.md",
    ],
)

deploydocs(;
    repo = "github.com/hlouzada/PrivateArtifacts.jl",
    devbranch = "main",
)
