{
  description = "Trivial cmark markdown2html derivation, used as a Gachix git-backed binary cache demo";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
    in
    {
      packages.${system} = {
        default = self.packages.${system}.hello-html;

        # Convert a "Hello, world!" markdown file to HTML with cmark.
        hello-html = pkgs.runCommand "hello-html"
          {
            nativeBuildInputs = [ pkgs.cmark ];
          }
          ''
            mkdir -p $out
            cat > hello.md <<'EOF'
            # Hello, world!

            This HTML was produced by a **trivial** Nix derivation using `cmark`,
            and the build output is served from a [Gachix](https://github.com/EphraimSiegfried/gachix)
            binary cache whose storage backend is a plain Git repository on GitHub.
            EOF
            cmark hello.md > $out/hello.html
          '';
      };
    };
}
