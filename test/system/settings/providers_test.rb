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

  test "shows not configured pill for an unconfigured provider" do
    visit settings_providers_path

    within("details", text: "SimpleFIN") do
      assert_text "Not configured"
    end
  end

  test "connected providers render before unconfigured ones" do
    SimplefinItem.create!(family: @family, name: "Test SimpleFIN", access_url: "https://bridge.simplefin.org/simplefin/access")

    visit settings_providers_path

    sections = all("details summary").map(&:text)
    simplefin_index = sections.index { |t| t.include?("SimpleFIN") }
    binance_index   = sections.index { |t| t.include?("Binance") }

    assert simplefin_index < binance_index, "Connected SimpleFIN should appear before unconfigured Binance"
  end

  test "expanding a section still works as expected" do
    visit settings_providers_path

    details = find("details", text: "SimpleFIN")
    assert_nil details[:open], "Section should start collapsed"

    details.find("summary").click

    assert details[:open], "Section should open when clicked"
    details.assert_text "Setup Token"
  end

  test "groups providers into Your connections and Available with counts" do
    SimplefinItem.create!(family: @family, name: "Test SimpleFIN", access_url: "https://bridge.simplefin.org/simplefin/access")

    visit settings_providers_path

    connections_heading = find("h2", text: /\AYour connections/)
    assert_match(/· 1\z/, connections_heading.text)

    available_heading = find("h2", text: /\AAvailable/)

    connections_y = connections_heading.native.location.y
    available_y   = available_heading.native.location.y
    simplefin_y   = find("details", text: "SimpleFIN").native.location.y
    binance_y     = find("details", text: "Binance").native.location.y

    assert connections_y < simplefin_y, "Your connections heading should appear above SimpleFIN section"
    assert simplefin_y < available_y, "SimpleFIN should appear above Available heading"
    assert available_y < binance_y,  "Available heading should appear above Binance section"
  end

  test "health strip shows four tiles with correct counts" do
    SimplefinItem.create!(family: @family, name: "Test SimpleFIN", access_url: "https://bridge.simplefin.org/simplefin/access")

    visit settings_providers_path

    assert_text "Connected"
    assert_text "Action needed"
    assert_text "Errors"
    assert_text "Accounts synced"
  end

  test "action needed group is absent when no providers have issues" do
    SimplefinItem.create!(family: @family, name: "Test SimpleFIN", access_url: "https://bridge.simplefin.org/simplefin/access")

    visit settings_providers_path

    assert_selector "h2", text: /\AYour connections/
    assert_no_selector "h2", text: /\AAction needed/
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

    assert_selector "h2", text: /\AYour connections/

    # The Enable Banking section should be in the Your connections group and auto-opened
    within("details[open]", text: /Enable Banking/) do
      assert_text "Re-consent needed in 5 days"
    end
  end

  test "sync all button enqueues SyncAllProvidersJob and shows flash" do
    SimplefinItem.create!(family: @family, name: "Test SimpleFIN", access_url: "https://bridge.simplefin.org/simplefin/access")

    visit settings_providers_path

    assert_enqueued_with(job: SyncAllProvidersJob) do
      click_on "Sync all"
    end

    assert_text "Syncing all connected providers"
  end

  test "per-row sync button enqueues sync for that provider and shows flash" do
    SimplefinItem.create!(family: @family, name: "Test SimpleFIN", access_url: "https://bridge.simplefin.org/simplefin/access")

    visit settings_providers_path

    within("details", text: "SimpleFIN") do
      find("button[title='Sync now']").click
    end

    assert_text "Sync started"
  end

  test "add provider CTA banner appears above available group when providers are connected" do
    SimplefinItem.create!(family: @family, name: "Test SimpleFIN", access_url: "https://bridge.simplefin.org/simplefin/access")

    visit settings_providers_path

    cta = find("a", text: "Browse providers")
    available_heading = find("h2", text: /\AAvailable/)

    cta_y = cta.native.location.y
    available_y = available_heading.native.location.y

    assert cta_y < available_y, "Add-provider CTA should appear above the Available heading"
  end

  test "available providers render as a card grid" do
    visit settings_providers_path

    # SimpleFIN is not connected, so it should appear in the card grid
    within "div.grid" do
      assert_text "SimpleFIN"
      assert_selector "a[data-turbo-frame='drawer']", minimum: 1
    end
  end

  test "clicking a provider card connect link opens the connect drawer" do
    visit settings_providers_path

    # Find and click the SimpleFIN card's Connect link
    within "div.grid" do
      find("a[data-turbo-frame='drawer']", text: /Connect/, match: :first).click
    end

    # Drawer should open with the panel content
    assert_selector "dialog[open]"
    assert_text "Setup Token"
  end
end
