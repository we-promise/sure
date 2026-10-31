#!/usr/bin/env bash
# libvips is a shared library, so adding its executable to PATH is not enough.
case "$(uname -s)" in
  Linux) export LD_LIBRARY_PATH="$SURE_VIPS_PREFIX/lib:$SURE_PG_PREFIX/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" ;;
  Darwin) export DYLD_FALLBACK_LIBRARY_PATH="$SURE_VIPS_PREFIX/lib:$SURE_PG_PREFIX/lib${DYLD_FALLBACK_LIBRARY_PATH:+:$DYLD_FALLBACK_LIBRARY_PATH}" ;;
esac

# The conda PostgreSQL package includes libpq headers but does not export pg_config.
export BUNDLE_BUILD__PG="--with-pg-include=\"$SURE_PG_PREFIX/include\" --with-pg-lib=\"$SURE_PG_PREFIX/lib\""
