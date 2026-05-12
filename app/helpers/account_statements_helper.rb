# frozen_string_literal: true

module AccountStatementsHelper
  ACCOUNT_STATEMENT_BALANCE_FIELDS = %w[opening_balance closing_balance].freeze

  def account_statement_status_badge(statement)
    case statement.review_status
    when "linked"
      render("shared/badge", color: "success") { t("account_statements.status.linked") }
    when "rejected"
      render("shared/badge", color: "warning") { t("account_statements.status.rejected") }
    else
      render("shared/badge") { t("account_statements.status.unmatched") }
    end
  end

  def account_statement_coverage_classes(status)
    case status.to_s
    when "not_expected"
      "bg-container-inset text-subdued ring-alpha-black-25"
    when "covered"
      "bg-success/10 text-success ring-success/20"
    when "duplicate", "ambiguous"
      "bg-warning/10 text-warning ring-warning/20"
    when "mismatched"
      "bg-destructive/10 text-destructive ring-destructive/20"
    else
      "bg-gray-tint-5 text-secondary ring-alpha-black-50"
    end
  end

  def account_statement_period(statement)
    if statement.period_start_on.present? && statement.period_end_on.present?
      "#{format_date(statement.period_start_on)} - #{format_date(statement.period_end_on)}"
    else
      t("account_statements.period.unknown")
    end
  end

  def account_statement_coverage_label(month)
    account_statement_month_label(month.date)
  end

  def account_statement_month_label(date)
    l(date, format: "%b %Y")
  end

  def account_statement_coverage_range(coverage)
    t(
      "account_statements.account_tab.coverage_range",
      start: account_statement_month_label(coverage.expected_start_month),
      end: account_statement_month_label(coverage.expected_end_month)
    )
  end

  def account_statement_reconciliation_label(check)
    key = check[:key] if check.respond_to?(:key?) && check.key?(:key)
    key ||= check["key"] if check.respond_to?(:key?) && check.key?("key")
    fallback = t("account_statements.reconciliation.checks.unknown_check")
    return fallback if key.blank?

    t(
      "account_statements.reconciliation.checks.#{key}",
      default: fallback
    )
  end

  def account_statement_balance_label(statement, field)
    return t("account_statements.balance.unknown") unless field.to_s.in?(ACCOUNT_STATEMENT_BALANCE_FIELDS)

    money = statement.public_send("#{field}_money")
    money ? money.format : t("account_statements.balance.unknown")
  end

  def account_statement_currency_options(statement)
    currency_picker_options_for_family(Current.family, extra: [ statement.currency ]).map do |code|
      currency = Money::Currency.new(code)
      [ "#{currency.name} (#{currency.iso_code})", currency.iso_code ]
    end
  end

  def account_statement_file_icon(statement)
    if statement.pdf?
      "file-text"
    elsif statement.xlsx?
      "sheet"
    else
      "file-spreadsheet"
    end
  end
end
