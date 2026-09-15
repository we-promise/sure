{
  description = "Sure - Finance application";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        ruby = pkgs.ruby_3_4;

        libs = with pkgs; [
          libpq
          vips
          libxml2
          libxslt
          libyaml
          libffi
          openssl
          jemalloc
          zlib
          gmp
        ];
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs =
            libs
            ++ (with pkgs; [
              ruby
              bundler
              nodejs_22
              postgresql_16
              redis
              overmind
              pkg-config
              gcc
              curl
              git
              gnumake
            ]);

          shellHook = ''
            export BUNDLE_BUILD__NOKOGIRI="--use-system-libraries"
            export BUNDLE_BUILD__PG="--with-pg-config=${pkgs.libpq}/bin/pg_config"

            echo "▸ Sure development environment"
            echo "  Ruby : $(ruby --version)"
            echo "  Node : $(node --version)"
            echo ""
            echo "  Run 'bin/setup' to set up the project"
            echo "  Run 'bin/dev' to start the dev server"
          '';

          LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath libs;
        };
      }
    );
}
