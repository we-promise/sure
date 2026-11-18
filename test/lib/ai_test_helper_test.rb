require "test_helper"

class AiTestHelperTest < ActiveSupport::TestCase
  test "a nested cassette scope leaves the outer one recording localhost" do
    with_env_overrides("AI_LIVE" => nil, "RECORD_CASSETTES" => nil) do
      with_ai_cassette(:llama_cpp, "nested_outer") do
        with_ai_cassette(:llama_cpp, "nested_inner") { }

        assert_not VCR.request_ignorer.localhost_ignored?
      end
    end
    assert VCR.request_ignorer.localhost_ignored?
  end
end
