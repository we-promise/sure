require "test_helper"

class Settings::ProviderCardTest < ViewComponent::TestCase
  test "external setup uses the provider label and opens outside the connection drawer" do
    render_inline(Settings::ProviderCard.new(provider_key: "example", name: "Example",
      external_link: { text: "Provider website", href: "https://example.com/setup" }))

    assert_selector "div[data-providers-filter-target='card']"
    assert_selector "a[href='https://example.com/setup'][target='_blank'][rel='noopener noreferrer'][data-turbo='false']",
      text: "Provider website"
    assert_no_selector "a[data-turbo-frame='drawer']"
    assert_no_selector "button[disabled]"
  end

  test "external setup without a URL shows the provider's disabled label and tooltip" do
    render_inline(Settings::ProviderCard.new(provider_key: "example", name: "Example",
      external_link: { text: "Provider website", href: nil, tooltip: "Setup unavailable" }))

    assert_selector "button[disabled]", text: "Provider website"
    assert_selector "[title='Setup unavailable'][tabindex='0'][aria-description='Setup unavailable']"
    assert_no_selector "a"
  end

  test "regular providers still open the connection drawer" do
    render_inline(Settings::ProviderCard.new(provider_key: "example", name: "Example"))

    assert_selector "a[data-providers-filter-target='card'][data-turbo-frame='drawer'][href='/settings/providers/example/connect_form']",
      text: "Connect"
  end

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
