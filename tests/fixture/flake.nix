{
  description = "Fixed-output derivations for the nix-flake-update tests";

  # No inputs: each package is a bare derivation, so a build needs neither
  # nixpkgs nor the network.
  outputs =
    { self }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      packagesFor =
        system:
        let
          # A fixed-output derivation writing its content, as a fetcher
          # writes the dependencies it downloads.
          fixed =
            name: content: hash:
            derivation {
              inherit name system content;
              builder = "/bin/sh";
              args = [
                "-c"
                "echo $content > $out"
              ];
              outputHashMode = "flat";
              outputHashAlgo = "sha256";
              outputHash = hash;
            };

          defaultContent = "default";
        in
        rec {
          default = fixed "default" defaultContent "sha256-AWZuwGBGbBS5+gbGE/usRJFj8qIBdVj+FlJiCat4xrA=";
          second = fixed "second" "second" "sha256-SAwjNrQQ8a1fi/GyiURJAlWAS2U1DFJ3h+dOvdUR46Q=";

          # Built from default, and fails unless it holds defaultContent, as go
          # build fails on vendored modules that are not the ones go.mod names.
          consumer = derivation {
            name = "consumer";
            inherit system;
            builder = "/bin/sh";
            args = [
              "-c"
              "read -r content < ${default}; [ \"$content\" = ${defaultContent} ] && echo ok > $out"
            ];
          };
        };
    in
    {
      packages = builtins.listToAttrs (
        map (system: {
          name = system;
          value = packagesFor system;
        }) systems
      );
    };
}
