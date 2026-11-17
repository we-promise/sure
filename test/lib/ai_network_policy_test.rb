require "test_helper"
require "open3"

class AiNetworkPolicyTest < ActiveSupport::TestCase
  POLICY_SCRIPT = Rails.root.join("script/ci/deny_provider_http.rb").to_s

  setup { @scratch_root = Dir.mktmpdir }
  teardown { FileUtils.remove_entry(@scratch_root) }

  test "an unstubbed request to a provider is refused" do
    error = assert_raises(VCR::Errors::UnhandledHTTPRequestError) do
      Net::HTTP.get(URI("https://api.openai.com/v1/models"))
    end

    assert_includes error.message, "api.openai.com"
  end

  test "no test file opens the network outside the live-cassette helper" do
    output, status = run_policy(Rails.root)

    assert status.success?, output
  end

  test "a test file that opens the network fails the policy, named with what it did" do
    {
      "WebMock.allow_net_connect!" => "WebMock.allow_net_connect!",
      "WebMock.disable_net_connect!(allow: \"api.openai.com\")" => "disable_net_connect!(allow: host)",
      "VCR.turned_off { get_models }" => "VCR.turned_off / VCR.turn_off!",
      "VCR.use_cassette(\"x\", record: :new_episodes) { }" => "a cassette recording live requests"
    }.each do |line, reported|
      output, status = run_policy(with_test_file(line))

      assert_not status.success?, line
      assert_includes output, "test/models/leaky_test.rb: #{reported}"
    end
  end

  test "closing the network again is allowed" do
    output, status = run_policy(with_test_file("WebMock.disable_net_connect!(allow_localhost: true)\nWebMock.reset!"))

    assert status.success?, output
  end

  private
    def run_policy(root)
      Open3.capture2e(RbConfig.ruby, POLICY_SCRIPT, root.to_s)
    end

    def with_test_file(source)
      FileUtils.mkdir_p(File.join(@scratch_root, "test/models"))
      File.write(File.join(@scratch_root, "test/models/leaky_test.rb"), source)
      @scratch_root
    end
end
