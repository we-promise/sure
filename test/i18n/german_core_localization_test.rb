require "test_helper"
require "yaml"

class GermanCoreLocalizationTest < ActiveSupport::TestCase
  CORE_LOCALE_FILES = %w[
    breadcrumbs
    models/category
    models/period
    views/accounts
    views/budgets
    views/categories
    views/chats
    views/components
    views/layout
    views/loans
    views/pages
    views/reports
    views/shared
    views/transactions
    views/users
  ].freeze

  test "German core locales match the English key structure" do
    missing_by_file = CORE_LOCALE_FILES.to_h do |relative_path|
      english = flattened_locale(relative_path, :en)
      german = flattened_locale(relative_path, :de)

      [ relative_path, english.keys - german.keys ]
    end.reject { |_path, missing| missing.empty? }

    assert_empty missing_by_file, missing_message(missing_by_file)
  end

  test "German core locales preserve English interpolation variables" do
    mismatches = CORE_LOCALE_FILES.flat_map do |relative_path|
      english = flattened_locale(relative_path, :en)
      german = flattened_locale(relative_path, :de)

      (english.keys & german.keys).filter_map do |key|
        english_variables = interpolation_variables(english[key])
        german_variables = interpolation_variables(german[key])
        next if english_variables == german_variables

        "#{relative_path}:#{key} (en=#{english_variables.inspect}, de=#{german_variables.inspect})"
      end
    end

    assert_empty mismatches, "Interpolation mismatches:\n#{mismatches.join("\n")}"
  end

  test "core frontend localization does not bypass I18n" do
    forbidden_patterns = {
      "app/views/accounts/_accountable_group.html.erb" => [ "singular_display_name.downcase" ],
      "app/views/budgets/_picker.html.erb" => [ "Date::ABBR_MONTHNAMES" ],
      "app/views/reports/_period_picker.html.erb" => [ "Date::ABBR_MONTHNAMES" ],
      "app/views/transactions/show.html.erb" => [ '[["Expense", "outflow"], ["Income", "inflow"]]' ],
      "app/views/layouts/shared/_footer.html.erb" => [ '"Privacy Policy"', '"Terms of Service"' ]
    }

    violations = forbidden_patterns.flat_map do |relative_path, patterns|
      source = Rails.root.join(relative_path).read
      patterns.filter_map do |pattern|
        "#{relative_path}: #{pattern}" if source.include?(pattern)
      end
    end

    assert_empty violations, "Hardcoded localization bypasses:\n#{violations.join("\n")}"
  end

  test "account group links use localized noun capitalization" do
    assert_equal "New loan", I18n.with_locale(:en) { localized_account_group_link(Loan) }
    assert_equal "Darlehen hinzufügen", I18n.with_locale(:de) { localized_account_group_link(Loan) }
    assert_equal "Nouveau prêt", I18n.with_locale(:fr) { localized_account_group_link(Loan) }
  end

  test "all period locales translate custom comparison ranges" do
    locale_paths = Rails.root.glob("config/locales/models/period/*.yml")

    locale_paths.each do |path|
      locale = path.basename(".yml").to_s
      period = flattened_locale("models/period", locale)

      assert_equal [ "end", "start" ], interpolation_variables(period.fetch("period.custom.comparison_label")), locale
    end
  end

  private
    def flattened_locale(relative_path, locale)
      path = Rails.root.join("config/locales/#{relative_path}/#{locale}.yml")
      return {} unless path.exist?

      data = YAML.safe_load_file(path, permitted_classes: [ Symbol ], aliases: true) || {}
      flatten(data.fetch(locale.to_s, {}))
    end

    def flatten(value, prefix = nil, result = {})
      if value.is_a?(Hash)
        value.each do |key, child|
          child_prefix = [ prefix, key ].compact.join(".")
          flatten(child, child_prefix, result)
        end
      else
        result[prefix] = value
      end

      result
    end

    def interpolation_variables(value)
      return [] unless value.is_a?(String)

      value.scan(/%\{([^}]+)\}/).flatten.uniq.sort
    end

    def localized_account_group_link(accountable_type)
      account_group_name = accountable_type.singular_display_name
      account_group_name = account_group_name.downcase unless I18n.t("accounts.sidebar.capitalize_account_group")

      I18n.t("accounts.sidebar.new_account_group", account_group: account_group_name)
    end

    def missing_message(missing_by_file)
      details = missing_by_file.map do |relative_path, keys|
        "#{relative_path}:\n  #{keys.join("\n  ")}"
      end

      "Missing German core translations:\n#{details.join("\n")}"
    end
end
