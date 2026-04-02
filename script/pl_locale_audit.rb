#!/usr/bin/env ruby
# frozen_string_literal: true

# Backward-compatible wrapper.
# Prefer: ruby script/locale_audit.rb --locale pl [--write-reports]

args = [ "--locale", "pl" ] + ARGV
exec("ruby", "script/locale_audit.rb", *args)
