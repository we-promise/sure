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

  test "shows a record name in the casing it was stored in" do
    data = CustomConfirm.for_resource_deletion("caroline@example.com").to_data_attribute

    assert_equal "Delete caroline@example.com?", data[:title]
    assert_equal "Are you sure you want to delete caroline@example.com? This is not reversible.", data[:body]
    assert_equal "Delete caroline@example.com", data[:confirmText]
  end

  test "keeps the casing of an all-caps record name" do
    data = CustomConfirm.for_resource_deletion("ANZ").to_data_attribute

    assert_equal "Delete ANZ?", data[:title]
    assert_includes data[:body], "delete ANZ?"
    assert_equal "Delete ANZ", data[:confirmText]
  end

  test "noun deletion keeps the English copy the hardcoded strings produced" do
    data = CustomConfirm.for_noun_deletion("rule").to_data_attribute

    assert_equal "Delete Rule?", data[:title]
    assert_equal "Are you sure you want to delete rule? This is not reversible.", data[:body]
    assert_equal "Delete Rule", data[:confirmText]
  end

  test "noun deletion titleizes a multi-word noun" do
    data = CustomConfirm.for_noun_deletion("all tags").to_data_attribute

    assert_equal "Delete All Tags?", data[:title]
    assert_includes data[:body], "delete all tags?"
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
    assert_equal "destructive", CustomConfirm.for_resource_deletion("caroline@example.com", high_severity: true).to_data_attribute[:variant]
    assert_equal "outline-destructive", CustomConfirm.for_resource_deletion("caroline@example.com").to_data_attribute[:variant]
  end

  # Record names go through `for_resource_deletion` untouched; English noun
  # literals go through `for_noun_deletion`. Keep the two from drifting.
  test "callers use the constructor that matches their argument" do
    files = Dir["app/views/**/*.erb"] + Dir["lib/generators/**/*.erb*"]

    literal_on_resource = files.select do |path|
      File.read(path).match?(/for_resource_deletion\(\s*["']/)
    end
    non_literal_on_noun = files.select do |path|
      File.read(path).match?(/for_noun_deletion\(\s*(?!["'])/)
    end

    assert_empty literal_on_resource, "noun literals must use for_noun_deletion"
    assert_empty non_literal_on_noun, "record names must use for_resource_deletion"
  end
end
