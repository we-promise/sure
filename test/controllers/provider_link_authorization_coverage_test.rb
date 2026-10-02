require "test_helper"

# Every provider that can link to an existing account must run the shared
# ProviderLinkAuthorizationTests, so a new provider cannot ship the #3534 gap.
class ProviderLinkAuthorizationCoverageTest < ActiveSupport::TestCase
  LINK_ACTIONS = %w[select_existing_account link_existing_account].freeze

  test "every existing-account link route has shared authorization tests" do
    controllers = Rails.application.routes.routes.filter_map do |route|
      route.defaults[:controller] if route.defaults[:action].in?(LINK_ACTIONS)
    end.uniq

    assert_operator controllers.size, :>=, 20

    missing = controllers.reject do |controller|
      test_file = Rails.root.join("test/controllers/#{controller}_controller_test.rb")
      test_file.exist? && calls_shared_tests?(test_file.read)
    end

    assert_empty missing, "Call provider_link_authorization_tests in these controllers' tests"
  end

  test "only a call counts, not a comment naming it" do
    refute calls_shared_tests?(<<~RUBY)
      # provider_link_authorization_tests(select_url: :select_existing_account_foo_items_url)
    RUBY
    assert calls_shared_tests?(<<~RUBY)
      include ProviderLinkAuthorizationTests
      provider_link_authorization_tests(
        select_url: :select_existing_account_foo_items_url
      )
    RUBY
  end

  private
    # The call must open a line, so a comment or prose mentioning it does not
    # satisfy the guard.
    def calls_shared_tests?(source)
      source.match?(/^[ \t]*provider_link_authorization_tests[ \t(]/)
    end
end
