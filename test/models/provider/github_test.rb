require "test_helper"

class Provider::GithubTest < ActiveSupport::TestCase
  test "release notes cache is scoped to the configured repository" do
    provider = Provider::Github.new

    Rails.cache.expects(:fetch)
      .with("latest_github_release_notes/we-promise/sure", expires_in: Provider::Github::CACHE_TTL)
      .yields
      .returns(nil)

    provider.client.expects(:releases).with("we-promise/sure").returns([])

    assert_nil provider.fetch_latest_release_notes
  end
end
