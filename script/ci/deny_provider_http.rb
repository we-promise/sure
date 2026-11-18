#!/usr/bin/env ruby
# frozen_string_literal: true

# Fails when a test file switches off the VCR/WebMock refusal of unstubbed requests, the one-line
# edit that would let a test reach a provider with a real key. Dependency-free so CI can run it
# before the app boots; test/lib/ai_network_policy_test.rb runs it too.
#
#   ruby script/ci/deny_provider_http.rb [ROOT]   # exit 1, listing the files, on a violation

ROOT = ARGV.first ? File.expand_path(ARGV.first) : File.expand_path("../..", __dir__)

ALLOWED = [
  "test/support/ai_test_helper.rb",     # with_ai_live opens the network on purpose, only under AI_LIVE=1
  "test/lib/ai_network_policy_test.rb"  # its examples are violations
].freeze

NETWORK_OPENERS = {
  "WebMock.allow_net_connect!" => /allow_net_connect/,
  "disable_net_connect!(allow: host)" => /disable_net_connect!\s*\(?[^)]*\ballow(?::|\s*=>)/,
  "WebMock.disable!" => /WebMock\.disable!/,
  "VCR.turned_off / VCR.turn_off!" => /VCR\.turn(ed)?_off/,
  "VCR allow_http_connections_*" => /allow_http_connections/,
  "VCR ignore_hosts" => /ignore_hosts/,
  "VCR ignore_request" => /ignore_request/,
  "a cassette recording live requests" => /(?:\brecord:|:record\s*=>)\s*:(all|new_episodes|once)/
}.freeze

# Openers a file may use this many times: test_helper.rb's ignore_request lets the system tests
# reach their Selenium server. A second one there is still reported.
ALLOWED_USES = { [ "test/test_helper.rb", "VCR ignore_request" ] => 1 }.freeze

offenses = Dir.glob("test/**/*.rb", base: ROOT).sort.flat_map do |path|
  next [] if ALLOWED.include?(path)

  source = File.read(File.join(ROOT, path))
  NETWORK_OPENERS.filter_map do |name, pattern|
    "#{path}: #{name}" if source.scan(pattern).size > ALLOWED_USES.fetch([ path, name ], 0)
  end
end

if offenses.any?
  warn "These test files open the network:"
  offenses.each { warn "  #{_1}" }
  warn "Live calls belong in with_ai_live (test/support/ai_test_helper.rb), under AI_LIVE=1."
  exit 1
end

puts "Network policy: no test file opens the network."
