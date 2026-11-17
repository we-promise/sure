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
  "disable_net_connect!(allow: host)" => /disable_net_connect!\s*\(?[^)\n]*\ballow:/,
  "WebMock.disable!" => /WebMock\.disable!/,
  "VCR.turned_off / VCR.turn_off!" => /VCR\.turn(ed)?_off/,
  "VCR allow_http_connections_*" => /allow_http_connections/,
  "VCR ignore_hosts" => /ignore_hosts/,
  "a cassette recording live requests" => /record:\s*:(all|new_episodes)/
}.freeze

offenses = Dir.glob("test/**/*.rb", base: ROOT).sort.flat_map do |path|
  next [] if ALLOWED.include?(path)

  source = File.read(File.join(ROOT, path))
  NETWORK_OPENERS.filter_map { |name, pattern| "#{path}: #{name}" if source.match?(pattern) }
end

if offenses.any?
  warn "These test files open the network:"
  offenses.each { warn "  #{_1}" }
  warn "Live calls belong in with_ai_live (test/support/ai_test_helper.rb), under AI_LIVE=1."
  exit 1
end

puts "Network policy: no test file opens the network."
