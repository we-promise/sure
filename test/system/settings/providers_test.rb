require "application_system_test_case"

class Settings::ProvidersTest < ApplicationSystemTestCase
  setup do
    @user = users(:family_admin)
    @family = families(:dylan_family)
    login_as @user
  end

  test "shows status pill on section header for a configured provider" do
    SimplefinItem.create!(family: @family, name: "Test SimpleFIN", access_url: "https://bridge.simplefin.org/simplefin/access")

    visit settings_providers_path

    within("details", text: "SimpleFIN") do
      assert_text "Connected"
    end
  end

  test "unconfigured SimpleFIN appears in Available with a connect affordance" do
    visit settings_providers_path

    assert_no_selector "details", text: "SimpleFIN"

    within available_provider_cards_container do
      assert_text "SimpleFIN"
      assert_selector "a[data-turbo-frame='drawer']", text: "Connect"
    end
  end

  test "connected providers are grouped under Your connections in alphabetical title order" do
    SimplefinItem.create!(family: @family, name: "Test SimpleFIN", access_url: "https://bridge.simplefin.org/simplefin/access")

    visit settings_providers_path

    titles = all("details").map { |d| d.find("summary h3", match: :first).text.squish }
    assert_equal titles.sort_by(&:downcase), titles, "Connection panels should render alphabetically by title"

    connections_heading = page.find(:xpath, "//h2[contains(translate(normalize-space(), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz'), 'your connections')]")
    available_heading = page.find(:xpath, "//h2[contains(translate(normalize-space(), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz'), 'available')]")
    connections_y = connections_heading.native.location.y
    available_y = available_heading.native.location.y

    assert_operator connections_y, :<, page.find("details", text: "SimpleFIN").native.location.y
    assert_operator page.find("details", text: "SimpleFIN").native.location.y, :<, available_y
  end

  test "expanding a section still works as expected" do
    SimplefinItem.create!(family: @family, name: "Test SimpleFIN", access_url: "https://bridge.simplefin.org/simplefin/access")

    visit settings_providers_path

    assert_selector "details:not([open])", text: "SimpleFIN"

    find("details", text: "SimpleFIN").find("summary").click

    assert_selector "details[open]", text: "SimpleFIN"
    within("details[open]", text: "SimpleFIN") do
      assert_text "Setup Token"
    end
  end

  test "groups providers into Your connections and Available with counts" do
    SimplefinItem.create!(family: @family, name: "Test SimpleFIN", access_url: "https://bridge.simplefin.org/simplefin/access")

    visit settings_providers_path

    connections_heading = find(:xpath, "//h2[contains(translate(., 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz'), 'your connections')]")
    normalized = connections_heading.text.squish
    assert_match(/Your connections .*· \d+/i, normalized)

    connections_y = connections_heading.native.location.y
    available_heading = find(:xpath, "//h2[contains(translate(., 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz'), 'available')]")
    available_y = available_heading.native.location.y
    simplefin_y = find("details", text: "SimpleFIN").native.location.y

    assert_operator connections_y, :<, simplefin_y, "Your connections heading should appear above SimpleFIN section"
    assert_operator simplefin_y, :<, available_y, "SimpleFIN should appear above Available heading"

    available_grid_top = available_provider_cards_container.native.location.y
    assert_operator available_y, :<, available_grid_top, "Available heading should appear above the card grid"
  end

  test "action needed group is absent when no providers have issues" do
    SimplefinItem.create!(family: @family, name: "Test SimpleFIN", access_url: "https://bridge.simplefin.org/simplefin/access")

    visit settings_providers_path

    assert_selector "h2", text: /\AYour connections/i
    assert_no_selector "h2", text: /\AAction needed/i
  end

  test "enable banking with expiring session appears in your connections and auto-opens" do
    item = EnableBankingItem.new(
      family: @family,
      name: "Test Bank",
      country_code: "DE",
      application_id: "test-app-id",
      session_id: "test-session",
      session_expires_at: 5.days.from_now
    )
    # Skip certificate validation for test purposes
    item.save!(validate: false)

    visit settings_providers_path

    assert_selector "h2", text: /\AYour connections/i

    # Auto-expanded warning sections hide compact meta behind `group-open:hidden`;
    # collapse once so the re-consent copy is visible again.
    enable = find("details", text: /Enable Banking/)
    enable.find("summary").click if enable.matches_selector?(":open")

    assert_selector "details:not([open])", text: /Enable Banking/
    assert_text "Re-consent needed in 5 days"
  end

  test "search input filters provider cards by name" do
    visit settings_providers_path

    find('[data-providers-filter-target="input"]').set("Coinbase")

    assert_selector "a[data-providers-filter-target='card']", text: /Coinbase/i
    assert_no_selector "a[data-providers-filter-target='card']", text: /Binance/i
  end

  test "kind chip narrows the grid to providers of that kind" do
    visit settings_providers_path

    click_on "Crypto"

    assert_selector "a[data-providers-filter-target='card']", text: /Coinbase/i
    assert_no_selector "a[data-providers-filter-target='card']", text: /SimpleFIN/i
  end

  test "search shows the empty filter message when no provider matches" do
    visit settings_providers_path

    find('[data-providers-filter-target="input"]').set("zzz_no_match_zzz")

    assert_selector '[data-providers-filter-target="empty"]', text: I18n.t("settings.providers.empty_filter")
    assert_no_selector "a[data-providers-filter-target='card']", visible: true
  end

  test "available providers render as a card grid" do
    visit settings_providers_path

    within available_provider_cards_container do
      assert_text "SimpleFIN"
      assert_selector "a[data-turbo-frame='drawer']", minimum: 1
    end
  end

  test "clicking a provider card opens the connect drawer" do
    visit settings_providers_path

    within available_provider_cards_container do
      find("a[data-turbo-frame='drawer']", text: "SimpleFIN").click
    end

    assert_selector "dialog[open]"
    assert_text "Setup Token"
  end

  test "configured plaid_eu surfaces in Your connections instead of Available" do
    Setting["plaid_eu_client_id"] = "test_eu_client"
    Setting["plaid_eu_secret"] = "test_eu_secret"

    visit settings_providers_path

    assert_selector "details summary h3", text: "Plaid EU"
    within available_provider_cards_container do
      assert_no_text "Plaid EU"
    end
  end

  test "clear filters button resets search input and chip state" do
    visit settings_providers_path

    find('[data-providers-filter-target="input"]').set("zzz_no_match_zzz")
    assert_selector '[data-providers-filter-target="empty"]', visible: true

    click_on I18n.t("settings.providers.clear_filter")

    assert_no_selector '[data-providers-filter-target="empty"]', visible: true
    assert_equal "", find('[data-providers-filter-target="input"]').value
    assert_selector "a[data-providers-filter-target='card']", text: /SimpleFIN/i
  end

  test "warn-state connection row carries warning outline class" do
    item = EnableBankingItem.new(
      family: @family,
      name: "Test Bank",
      country_code: "DE",
      application_id: "test-app-id",
      session_id: "test-session",
      session_expires_at: 5.days.from_now
    )
    item.save!(validate: false)

    visit settings_providers_path

    details = find("details", text: /Enable Banking/)
    assert_includes details[:class], "border-warning/25"
  end

  private

    # Card grid rendered after the `#available` group heading (following sibling div.grid)
    def available_provider_cards_container
      find("#available").find(:xpath, "following-sibling::div[contains(concat(' ', normalize-space(@class), ' '), ' grid ')]")
    end
end
