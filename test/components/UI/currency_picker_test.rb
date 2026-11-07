require "test_helper"

class UI::CurrencyPickerTest < ViewComponent::TestCase
  CURRENCIES = %w[USD EUR GBP].map { |code| Money::Currency.new(code) }.freeze

  test "renders one menuitemradio link per currency, all carrying the currency param and target frame" do
    render_inline(UI::CurrencyPicker.new(selected: "USD", currencies: CURRENCIES, url: "/", frame: "dashboard_sections"))

    links = page.all("a[role='menuitemradio']")
    assert_equal CURRENCIES.size, links.size

    CURRENCIES.zip(links).each do |currency, link|
      assert_match(/currency=#{currency.iso_code}/, link[:href])
      assert_equal "dashboard_sections", link["data-turbo-frame"]
      assert_includes link.text, currency.name
    end
  end

  test "marks the selected currency with aria-checked and a check glyph" do
    render_inline(UI::CurrencyPicker.new(selected: "EUR", currencies: CURRENCIES, url: "/"))

    selected = page.all("a[role='menuitemradio'][aria-checked='true']")
    assert_equal 1, selected.size
    assert_match(/currency=EUR/, selected.first[:href])
    assert_selector "a[aria-checked='true'] svg"
  end

  test "trigger shows the selected code and announces it" do
    render_inline(UI::CurrencyPicker.new(selected: Money::Currency.new("GBP"), currencies: CURRENCIES, url: "/"))

    assert_selector "button[aria-label='Currency: GBP']", text: "GBP"
  end

  test "trigger accessible name follows the locale" do
    I18n.with_locale(:de) do
      render_inline(UI::CurrencyPicker.new(selected: "GBP", currencies: CURRENCIES, url: "/"))

      assert_selector "button[aria-label='Währung: GBP']"
    end
  end

  test "extra_params are merged into every option href" do
    render_inline(UI::CurrencyPicker.new(
      selected: "USD",
      currencies: CURRENCIES,
      url: "/",
      extra_params: { start_date: "2026-01-01", end_date: "2026-01-31" }
    ))

    page.all("a[role='menuitemradio']").each do |link|
      assert_match(%r{\A/\?}, link[:href])
      assert_match(/start_date=2026-01-01/, link[:href])
      assert_match(/currency=/, link[:href])
    end
  end

  test "other currencies advance the URL while the checked one replaces" do
    render_inline(UI::CurrencyPicker.new(selected: "USD", currencies: CURRENCIES, url: "/", frame: "dashboard_sections"))

    assert_selector "a[role='menuitemradio'][aria-checked='true'][data-turbo-action='replace']", count: 1
    assert_selector "a[role='menuitemradio'][aria-checked='false'][data-turbo-action='advance']", count: CURRENCIES.size - 1
  end
end
