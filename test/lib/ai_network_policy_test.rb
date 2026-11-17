require "test_helper"

# Tests must never reach a provider or any other network service. VCR/WebMock
# already refuse an unstubbed request (the first test pins what that looks like),
# and the second test fails the build for any test file that quietly opens the
# network instead. The live-cassette helper is the one exception:
# test/support/ai_test_helper.rb's `with_ai_live` opens the network deliberately,
# scoped to a block, outside of `AI_LIVE=1`/`RECORD_CASSETTES=1` it changes nothing.
class AiNetworkPolicyTest < ActiveSupport::TestCase
  # The files permitted to enable real network access. Everything else that
  # mentions one of these patterns is bypassing the guard the whole suite
  # relies on.
  ALLOWED_FILES = %w[
    test/support/ai_test_helper.rb
  ].freeze

  NETWORK_PATTERNS = [
    /allow_net_connect/,
    /WebMock\.(allow|allow_net_connect|disable|disable!|enable)\b/,
    /VCR\.(allow_http_connections_after_connect_failure|turned_off|turn_off!|eject_cassette)\b/,
    /VCR\.configuration\.record=/
  ].freeze

  test "an unstubbed request to a provider is refused, and nothing reached the wire" do
    error = assert_raises(VCR::Errors::UnhandledHTTPRequestError) do
      Net::HTTP.get(URI("https://api.openai.com/v1/models"))
    end

    assert_includes error.message, "api.openai.com"
  end

  test "no test file opens the network outside the live-cassette helper" do
    offending = scan_test_files.flat_map do |path, source|
      NETWORK_PATTERNS.filter_map do |pattern|
        "#{path}: /#{pattern.source}/" if source.match?(pattern)
      end
    end

    assert_empty offending, -> {
      "Test files that open the network (the policy is no live calls outside AI_LIVE=1):\n#{offending.join("\n")}"
    }
  end

  private
    def scan_test_files
      Dir.glob(Rails.root.join("test", "**", "*.rb")).filter_map do |file|
        relative = Pathname.new(file).relative_path_from(Rails.root).to_s
        next if ALLOWED_FILES.include?(relative)
        next if relative == "test/lib/ai_network_policy_test.rb"
        next if relative.start_with?("test/fixtures/", "test/vcr_cassettes/")

        [ relative, File.read(file) ]
      end
    end
end
