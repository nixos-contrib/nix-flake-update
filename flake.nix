{
  description = "Update a flake: flake.lock, stale fixed-output hashes, and a pull request";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      nixpkgs,
      flake-utils,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # What the scripts call. nix is not here: it is the host's, since the
        # repair builds with the flakes configuration the user has.
        runtimeInputs = with pkgs; [
          bash
          coreutils
          findutils
          gawk
          gh
          git
          gnugrep
          gnused
          jq
          perl
        ];

        nix-update = pkgs.stdenvNoCC.mkDerivation {
          name = "nix-update";
          src = pkgs.lib.fileset.toSource {
            root = ./.;
            fileset = pkgs.lib.fileset.unions [
              ./nix-update
              ./update-lock.sh
              ./repair-hashes.sh
              ./deliver.sh
            ];
          };
          nativeBuildInputs = [ pkgs.makeWrapper ];
          dontBuild = true;
          # The scripts stay together, since the command finds the others next
          # to itself.
          installPhase = ''
            install -Dm0755 -t $out/libexec/nix-update \
              nix-update update-lock.sh repair-hashes.sh deliver.sh
            makeWrapper $out/libexec/nix-update/nix-update $out/bin/nix-update \
              --prefix PATH : ${pkgs.lib.makeBinPath runtimeInputs}
          '';
          meta = {
            description = "Update a flake: flake.lock, stale fixed-output hashes, and a pull request";
            mainProgram = "nix-update";
          };
        };
      in
      {
        packages.default = nix-update;

        devShells.default = pkgs.mkShell {
          name = "nix-update";
          # Not runtimeInputs: the tests should run with the runner's own sed,
          # awk and grep, as the action does on macOS, not GNU ones.
          packages = with pkgs; [
            bash
            git
            jq
            perl
            shellcheck
            actionlint
          ];
        };
      }
    );
}
