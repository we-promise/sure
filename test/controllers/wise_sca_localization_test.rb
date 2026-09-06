require "test_helper"

class WiseScaLocalizationTest < ActiveSupport::TestCase
  TRANSLATIONS = {
    "title" => "Starke Kundenauthentifizierung (SCA)",
    "description" => "Wise benötigt eine signierte Einmal-Token-Challenge, um vollständige Kontoauszüge einschließlich eingehender Zahlungen abzurufen. Erzeuge hier ein Schlüsselpaar und registriere den öffentlichen Schlüssel bei Wise, um den vollständigen Abruf zu ermöglichen.",
    "public_key_label" => "Öffentlicher Schlüssel (PEM)",
    "registered_help_html" => "Registriere diesen Schlüssel bei Wise: Settings → Connect and manage apps → Developer tools → Public keys → Add public key.",
    "copy" => "Kopieren",
    "copied" => "Kopiert!",
    "generate" => "Schlüsselpaar erzeugen",
    "regenerate" => "Neues Schlüsselpaar erzeugen",
    "regenerate_confirm" => "Dadurch wird ein neues Schlüsselpaar erzeugt. Wise akzeptiert den bisherigen öffentlichen Schlüssel weiterhin, bis du ihn selbst in deinem Wise-Konto entfernst – Sure kann ihn nicht aus der Ferne widerrufen. Du musst den neuen öffentlichen Schlüssel bei Wise registrieren, bevor Kontoauszüge wieder synchronisiert werden können. Fortfahren?"
  }.freeze

  test "German Wise SCA copy matches the expected translations" do
    TRANSLATIONS.each do |key, expected|
      full_key = "wise_items.provider_panel.sca.#{key}"

      assert I18n.exists?(full_key, :de, fallback: false), "de is missing #{full_key}"
      assert_equal expected, I18n.t(full_key, locale: :de, resolve: false)
    end
  end
end

class WiseScaPanelLocalizationTest < ActionDispatch::IntegrationTest
  setup do
    ensure_tailwind_build
    sign_in @user = users(:family_admin)
    @user.update!(locale: "de")
  end

  test "German Wise panel renders the SCA setup state" do
    get connect_form_settings_providers_path(provider_key: "wise")

    assert_response :success
    assert_sca_copy "title"
    assert_sca_copy "description"
    assert_sca_copy "generate"
  end

  test "German Wise panel renders configured SCA guidance and regeneration warning" do
    WiseItem.any_instance.stubs(:sca_public_key).returns("SYNTHETIC PUBLIC KEY")

    get connect_form_settings_providers_path(provider_key: "wise")

    assert_response :success
    assert_includes response.body, "SYNTHETIC PUBLIC KEY"
    assert_sca_copy "public_key_label"
    assert_sca_copy "registered_help_html"
    assert_sca_copy "copy"
    assert_sca_copy "copied"
    assert_sca_copy "regenerate"
    assert_sca_copy "regenerate_confirm"
  end

  private

    def assert_sca_copy(key)
      expected = WiseScaLocalizationTest::TRANSLATIONS.fetch(key)
      assert_includes response.body, ERB::Util.html_escape(expected)
    end
end
