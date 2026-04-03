#!/usr/bin/env ruby
# frozen_string_literal: true

# Backward-compatible wrapper.
# Prefer: ruby script/locale_audit.rb --locale pl [--write-reports]

filtered_argv = []
skip_next = false

ARGV.each do |arg|
  if skip_next
    skip_next = false
    next
  end

  if arg == "--locale"
    skip_next = true
    next
  end

  if arg.start_with?("--locale=")
    next
  end

  filtered_argv << arg
end

args = [ "--locale", "pl" ] + filtered_argv
exec(RbConfig.ruby, "script/locale_audit.rb", *args)
