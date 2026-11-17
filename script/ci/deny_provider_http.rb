#!/usr/bin/env ruby
# frozen_string_literal: true

# CI guard: the test suite must not open the network. VCR/WebMock already
# enforce that at runtime (an unstubbed request raises VCR::Errors::
# UnhandledHTTPRequestError); this script fails the build for any test file that
# quietly disables those guards, which is the one edit that undoes them silently.
# Keep it dependency-free; it runs before the test jobs' boot.
#
# Exit 0 when clean, 1 with the offending files listed otherwise.

ROOT = File.expand_path("../..", __dir__)

ALLOWED = %w[
  test/support/ai_test_helper.rb
].freeze

NETWORK_PATTERNS = [
  /allow_net_connect/,
  /WebMock\.(allow|allow_net_connect|disable|disable!|enable)\b/,
  /VCR\.(allow_http_connections_after_connect_failure|turned_off|turn_off!|eject_cassette)\b/,
  /VCR\.configuration\.record=/
].freeze

offenses = []
Dir.glob(File.join(ROOT, "test", "**", "*.rb")).each do |file|
  relative = file.delete_prefix("#{ROOT}/")
  next if ALLOWED.include?(relative)
  next if relative == "test/lib/ai_network_policy_test.rb"
  next if relative.start_with?("test/fixtures/", "test/vcr_cassettes/")

  source = File.read(file)
  NETWORK_PATTERNS.each do |pattern|
    offenses << "#{relative}: /#{pattern.source}/" if source.match?(pattern)
  end
end

if offenses.any?
  warn "Network policy violated; these test files re-enable the network:"
  offenses.each { warn "  #{_1}" }
  warn "Live tests run only under AI_LIVE=1 / RECORD_CASSETTES=1 via test/support/ai_test_helper.rb."
  exit 1
end

puts "Network policy: no test file opens the network."
