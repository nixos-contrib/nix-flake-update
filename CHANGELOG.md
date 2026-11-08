# Changelog

## [1.0.1](https://github.com/nixos-contrib/nix-update/compare/v1.0.0...v1.0.1) (2026-11-08)


### Bug Fixes

* **ci:** ignore the stale actionlint inputs in merge.yml too ([ff2ee59](https://github.com/nixos-contrib/nix-update/commit/ff2ee599c8850e317275b378cca6137f9b33f0eb))
* **ci:** merge with the App token so main gets its CI run ([#11](https://github.com/nixos-contrib/nix-update/issues/11)) ([2cf020e](https://github.com/nixos-contrib/nix-update/commit/2cf020e3dcd54df7fa161b2272f5da82e63681ae))
* **ci:** stop forcing every release to 1.0.0 ([#14](https://github.com/nixos-contrib/nix-update/issues/14)) ([d2bc43b](https://github.com/nixos-contrib/nix-update/commit/d2bc43bc40db489bad97e49fd60d02aa642e2a34))

## 1.0.0 (2026-11-07)


### Features

* rename to nix-flake-update and update flake.lock with pull requests ([#8](https://github.com/nixos-contrib/nix-update/issues/8)) ([b78c1ee](https://github.com/nixos-contrib/nix-update/commit/b78c1ee2684242416f0f24d738280d04df57d9b9))
* repair stale fixed-output hashes and push the fix ([#1](https://github.com/nixos-contrib/nix-update/issues/1)) ([1eb80ce](https://github.com/nixos-contrib/nix-update/commit/1eb80ce9ac3e9d189df51ba380b2b5e337a8299a))
* run from the command line as nix-update ([#10](https://github.com/nixos-contrib/nix-update/issues/10)) ([c5e1f38](https://github.com/nixos-contrib/nix-update/commit/c5e1f38ecf22064f2ac3f74e6820157c07a15e24))


### Bug Fixes

* catch a stale hash whose old output is already cached ([#3](https://github.com/nixos-contrib/nix-update/issues/3)) ([a31767e](https://github.com/nixos-contrib/nix-update/commit/a31767e474956dc5980e8cdf59aebc39e9b0cbe0))
