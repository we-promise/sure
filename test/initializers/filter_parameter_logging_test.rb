require "test_helper"

class FilterParameterLoggingTest < ActiveSupport::TestCase
  setup do
    @filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
  end

  # MFA codes, OAuth/bank authorization codes and the desktop SSO exchange all
  # arrive as a bare "code" and are credentials until they are spent.
  test "filters one-time codes and other bearer values from logs" do
    filtered = @filter.filter(
      code: "123456",
      linking_code: "abc",
      invite_code: "deadbeef",
      user: { invite_code: "deadbeef" },
      simplefin_item: { access_url: "https://user:secret@bridge.example/simplefin" }
    )

    assert_equal "[FILTERED]", filtered[:code]
    assert_equal "[FILTERED]", filtered[:linking_code]
    assert_equal "[FILTERED]", filtered[:invite_code]
    assert_equal "[FILTERED]", filtered.dig(:user, :invite_code)
    assert_equal "[FILTERED]", filtered.dig(:simplefin_item, :access_url)
  end

  test "keeps descriptive codes readable" do
    filtered = @filter.filter(currency_code: "EUR", country_code: "DE", postal_code: "10115")

    assert_equal "EUR", filtered[:currency_code]
    assert_equal "DE", filtered[:country_code]
    assert_equal "10115", filtered[:postal_code]
  end
end
