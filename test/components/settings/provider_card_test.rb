require "test_helper"

class Settings::ProviderCardTest < ActiveSupport::TestCase
  test "metadata line displays multiple kinds" do
    card = Settings::ProviderCard.new(
      provider_key: "example",
      name: "Example",
      region: "US",
      kinds: %w[Bank Investment],
      tier: "Paid"
    )

    assert_equal "US · Bank / Investment · Paid", card.meta_line
  end

  test "filter data includes all kinds as searchable tokens" do
    card = Settings::ProviderCard.new(
      provider_key: "example",
      name: "Example",
      kinds: %w[Bank Investment]
    )

    assert_equal "bank investment", card.filter_data[:provider_kind]
  end

  test "metadata line displays a single kind" do
    card = Settings::ProviderCard.new(
      provider_key: "example",
      name: "Example",
      kinds: %w[Crypto]
    )

    assert_equal "Crypto", card.meta_line
    assert_equal "crypto", card.filter_data[:provider_kind]
  end
end
