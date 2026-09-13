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
      test_file.exist? && test_file.read.include?("provider_link_authorization_tests(")
    end

    assert_empty missing, "Call provider_link_authorization_tests in these controllers' tests"
  end
end
