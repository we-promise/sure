require "test_helper"

class CustomConfirmTest < ActiveSupport::TestCase
  # `confirm_dialog_controller` renders `body` with textContent, so a record
  # named "<img src=x onerror=…>" shows as that text. Escaping it here as well
  # would print the entities: "rock &amp; roll" instead of "rock & roll".
  test "passes the resource name through as text" do
    assert_includes CustomConfirm.for_resource_deletion("<img src=x onerror=alert(1)>").to_data_attribute[:body],
      "<img src=x onerror=alert(1)>"
    assert_includes CustomConfirm.for_resource_deletion("Rock & Roll").to_data_attribute[:body], "Rock & Roll"
  end

  test "keeps a record name exactly as stored" do
    {
      "caroline@example.com" => "caroline@example.com",
      "ANZ" => "ANZ",
      "McDonald's" => "McDonald's"
    }.each do |name, shown|
      data = CustomConfirm.for_resource_deletion(name).to_data_attribute

      assert_equal "Delete #{shown}?", data[:title]
      assert_equal "Are you sure you want to delete #{shown}? This is not reversible.", data[:body]
      assert_equal "Delete #{shown}", data[:confirmText]
    end
  end

  test "keeps the English copy the hardcoded strings produced" do
    data = CustomConfirm.for_noun_deletion("rule").to_data_attribute

    assert_equal "Delete Rule?", data[:title]
    assert_equal "Are you sure you want to delete rule? This is not reversible.", data[:body]
    assert_equal "Delete Rule", data[:confirmText]

    questrade = CustomConfirm.for_noun_deletion("Questrade").to_data_attribute
    assert_equal "Delete Questrade?", questrade[:title]
    assert_equal "Are you sure you want to delete questrade? This is not reversible.", questrade[:body]
  end

  # These back ~40 call sites across the app, so a locale that ships the
  # sibling `default_*` copy should ship these too. Locales without a
  # `custom_confirm` block at all are left out on purpose — adding one would
  # invent structure they have not adopted, and fallbacks cover them.
  test "resource-deletion copy resolves wherever the sibling default copy lives" do
    localized = Dir["config/locales/views/shared/*.yml"].filter_map do |path|
      locale = File.basename(path, ".yml")
      next unless I18n.exists?("shared.custom_confirm.default_title", locale)
      locale
    end

    assert_operator localized.size, :>, 1, "expected more than just English to define this block"

    localized.each do |locale|
      body = I18n.t("shared.custom_confirm.resource_deletion_body", resource: "Wedding", locale: locale)
      assert_includes body, "Wedding", "#{locale} dropped the %{resource} interpolation"
      assert I18n.t("shared.custom_confirm.resource_deletion_title", resource: "x", locale: locale).present?
      assert I18n.t("shared.custom_confirm.resource_deletion_btn_text", resource: "x", locale: locale).present?
    end
  end

  test "high severity picks the destructive button variant" do
    assert_equal "destructive", CustomConfirm.for_resource_deletion("rule", high_severity: true).to_data_attribute[:variant]
    assert_equal "outline-destructive", CustomConfirm.for_resource_deletion("rule").to_data_attribute[:variant]
    assert_equal "destructive", CustomConfirm.for_noun_deletion("rule", high_severity: true).to_data_attribute[:variant]
    assert_equal "outline-destructive", CustomConfirm.for_noun_deletion("rule").to_data_attribute[:variant]
  end

  # `for_noun_deletion` re-cases its argument, which suits a fixed English noun
  # but mangles a record's own name ("ANZ" -> "Anz"). Each constructor must
  # only ever see its own kind of argument.
  test "noun literals and record names each use their own constructor" do
    sources = Dir["app/{views,components}/**/*.erb", "lib/generators/**/*.tt"]

    calls = sources.flat_map do |path|
      File.read(path).scan(/CustomConfirm\.(for_resource_deletion|for_noun_deletion)\(\s*(\S)/).map do |method, first_char|
        [ path, method, first_char == '"' ]
      end
    end

    assert_operator calls.size, :>, 40, "expected the scan to find the delete dialogs"

    calls.each do |path, method, literal|
      if method == "for_noun_deletion"
        assert literal, "#{path} passes a record name to for_noun_deletion, which re-cases it"
      else
        assert_not literal, "#{path} passes a noun literal to for_resource_deletion; use for_noun_deletion"
      end
    end
  end
end
