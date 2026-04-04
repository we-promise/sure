#!/usr/bin/env ruby
# frozen_string_literal: true

args = []
i = 0

while i < ARGV.length
  arg = ARGV[i]
  if arg == "--locale"
    i += 2
  elsif arg.start_with?("--locale=")
    i += 1
  else
    args << arg
    i += 1
  end
end

exec(RbConfig.ruby, "script/locale_audit.rb", "--locale", "pl", *args)
