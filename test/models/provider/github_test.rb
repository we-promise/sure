require "test_helper"

class Provider::GithubTest < ActiveSupport::TestCase
  setup do
    @provider = Provider::Github.new
    @memory_cache = ActiveSupport::Cache::MemoryStore.new
  end

  test "fetch_release_notes returns serialized notes for the exact tag" do
    release = mock
    author = mock
    author.stubs(:avatar_url).returns("https://github.com/we-promise.png")
    author.stubs(:login).returns("we-promise")
    release.stubs(author: author, name: "v1.0.0", published_at: Time.current, body: "notes")

    client = mock
    client.expects(:release_for_tag).with("we-promise/sure", "v1.0.0").returns(release)
    client.expects(:markdown).with("notes", mode: "gfm", context: "we-promise/sure").returns("<p>notes</p>")
    @provider.stubs(:client).returns(client)

    notes = @provider.fetch_release_notes("v1.0.0")

    assert_equal "v1.0.0", notes[:name]
    assert_equal "<p>notes</p>", notes[:body]
  end

  test "failed lookups are cached briefly instead of retried every request" do
    client = mock
    client.expects(:release_for_tag).once.raises(Octokit::NotFound)
    @provider.stubs(:client).returns(client)

    Rails.stubs(:cache).returns(@memory_cache)

    assert_nil @provider.fetch_release_notes("v0.0.0-missing")
    assert_nil @provider.fetch_release_notes("v0.0.0-missing")
  end

  test "a release missing from GitHub is cached briefly instead of retried every request" do
    client = mock
    client.expects(:release_for_tag).once.returns(nil)
    @provider.stubs(:client).returns(client)

    Rails.stubs(:cache).returns(@memory_cache)

    assert_nil @provider.fetch_release_notes("v0.0.0-missing")
    assert_nil @provider.fetch_release_notes("v0.0.0-missing")
  end
end
