{
  description = "Sure development shell";

  inputs = {
    flake-utils.url = "github:numtide/flake-utils";
    nixpkgs-ruby-3-4-7.url = "github:nixos/nixpkgs/ee09932cedcef15aaf476f9343d1dea2cb77e261";
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
  };

  outputs = {
    flake-utils,
    nixpkgs-ruby-3-4-7,
    nixpkgs,
    ...
  }:
    flake-utils.lib.eachDefaultSystem (
      system: let
        pkgs = nixpkgs.legacyPackages.${system};
        rubyPkgs = nixpkgs-ruby-3-4-7.legacyPackages.${system};

        chromium = pkgs.chromium;
        chromeBin = "${chromium}/bin/chromium";
        chromedriver = pkgs.chromedriver;

        googleChromeShim = pkgs.writeShellScriptBin "google-chrome" ''
          exec "${chromeBin}" "$@"
        '';

        googleChromeStableShim = pkgs.writeShellScriptBin "google-chrome-stable" ''
          exec "${chromeBin}" "$@"
        '';

        # All libraries used to build and link native gem extensions must come
        # from the same nixpkgs pin as Ruby so they share a compatible glibc.
        # Mixing pins here causes GLIBC version mismatches at runtime via
        # LD_LIBRARY_PATH.
        buildAndRuntimeLibs = with rubyPkgs; [
          imagemagick
          libffi
          libxml2
          libxslt
          libyaml
          openssl
          postgresql_16
          readline
          stdenv.cc.cc.lib
          vips
          zlib
        ];

        libsPath = rubyPkgs.lib.makeLibraryPath buildAndRuntimeLibs;
      in {
        devShells.default = pkgs.mkShell {
          packages = [
            googleChromeShim
            googleChromeStableShim

            chromedriver
            chromium

            pkgs.curl
            pkgs.git
            pkgs.nodejs_20
            pkgs.redis
            pkgs.tailwindcss_4

            (rubyPkgs.bundler.override {ruby = rubyPkgs.ruby_3_4;})
            rubyPkgs.postgresql_16.pg_config
            rubyPkgs.ruby_3_4
          ];

          nativeBuildInputs = with pkgs; [
            pkg-config
          ];

          buildInputs = buildAndRuntimeLibs;

          shellHook = ''
            export GEM_HOME="$PWD/tmp/.gem"
            export GEM_PATH="$GEM_HOME"
            export BUNDLE_PATH="$PWD/.bundle"
            export BUNDLE_BIN="$BUNDLE_PATH/bin"
            export PATH="$GEM_HOME/bin:$BUNDLE_BIN:$PATH"

            export PG_CONFIG="${rubyPkgs.postgresql_16.pg_config}/bin/pg_config"
            export BUNDLE_BUILD__PG="--with-pg-config=$PG_CONFIG"

            # Prevent Bundler from switching to the version in BUNDLED WITH,
            # so the Nix-provided Bundler is always used as-is.
            export BUNDLE_VERSION=system

            export LIBRARY_PATH="${libsPath}:''${LIBRARY_PATH:-}"
            export LD_LIBRARY_PATH="${libsPath}:''${LD_LIBRARY_PATH:-}"

            export TAILWINDCSS_INSTALL_DIR="${pkgs.tailwindcss_4}/bin"
            export CHROME_BIN="${chromeBin}"
            export CHROMEDRIVER_PATH="${chromedriver}/bin/chromedriver"
            export GOOGLE_CHROME_SHIM="$CHROME_BIN"

            # PostgreSQL utils
            export PGDATA="$PWD/tmp/postgres/data"
            export PGHOST="$PWD/tmp/postgres"

            pg_start() {
              if [ ! -d "$PGDATA" ]; then
                echo "Initializing local PostgreSQL database in tmp/postgres/..."
                mkdir -p "$PGHOST"
                initdb --no-locale --encoding=UTF8 --auth=trust --no-instructions --username=postgres \
                  -c "listen_addresses=" \
                  -c "unix_socket_directories=$PGHOST"
              fi
              pg_ctl start -l "$PWD/tmp/postgres/postgres.log"
            }

            pg_stop() {
              pg_ctl stop
            }

            # Redis utils
            export REDIS_DIR="$PWD/tmp/redis"
            redis_start() {
              mkdir -p "$REDIS_DIR"
              redis-server --daemonize yes \
                --logfile "$REDIS_DIR/redis.log" \
                --pidfile "$REDIS_DIR/redis.pid" \
                --dir "$REDIS_DIR"
            }

            redis_stop() {
              redis-cli shutdown nosave 2>/dev/null || true
            }

            echo "Development environment loaded:"
            echo "  BUNDLE_PATH: $BUNDLE_PATH"
            echo "  GEM_HOME: $GEM_HOME"
            echo ""
            echo "  bundler: $(bundle --version)"
            echo "  chromium: $(chromium --version)"
            echo "  node: $(node --version)"
            echo "  postgres: $(psql --version)"
            echo "  redis: $(redis-server --version | head -n 1)"
            echo "  ruby: $(ruby -v)"
            echo "  tailwindcss: ${pkgs.tailwindcss_4.version}"
            echo ""
            echo "To get started, run:"
            echo "1. 'bundle install'"
            echo "2. 'pg_start' to start PostgreSQL and 'redis_start' to start Redis."
            echo "3. 'bin/rails db:setup' to set up the database (only needed if the database is not already set up)."
            echo "4. 'bin/dev' to start the Rails server."
            echo ""
            echo "Remember to run 'pg_stop' and 'redis_stop' when you're done to cleanly shut down the database and Redis server."
          '';
        };
      }
    );
}
