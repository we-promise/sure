require "test_helper"

class SafeReturnPathTest < ActiveSupport::TestCase
  class Host
    include SafeReturnPath

    attr_reader :params

    def initialize(return_to)
      @params = ActionController::Parameters.new(return_to: return_to)
    end

    def call
      safe_return_to_path
    end
  end

  test "keeps a path on this site, with its query string and without surrounding whitespace" do
    assert_equal "/accounts", Host.new("/accounts").call
    assert_equal "/accounts?tab=manual", Host.new("/accounts?tab=manual").call
    assert_equal "/accounts", Host.new("  /accounts ").call
  end

  test "rejects paths that leave the site or cannot be trusted" do
    [
      "https://evil.example/accounts",
      "//evil.example",
      "///evil.example",
      "/\\evil.example",
      "/accounts\\evil.example",
      "/\t/evil.example",
      "/acc\tounts",
      "/%2Fevil.example",
      "/%2fevil.example",
      "/%5Cevil.example",
      "/%zzevil.example",
      "accounts"
    ].each do |return_to|
      assert_nil Host.new(return_to).call, "#{return_to.inspect} should be rejected"
    end
  end

  test "rejects a path that does not route" do
    assert_nil Host.new("/no-such-route-here").call
  end

  test "rejects a bare slash so the caller's own default applies" do
    assert_nil Host.new("/").call
  end

  test "returns nil when no return path is given" do
    assert_nil Host.new(nil).call
    assert_nil Host.new("").call
  end
end
