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
end
