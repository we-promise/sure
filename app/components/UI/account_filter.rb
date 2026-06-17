class UI::AccountFilter < ApplicationComponent
  # Multi-account filter picker shared by dashboard, reports, and budget pages.
  #
  # Renders a DS::Popover with a checkbox form. Submitting the form reloads the
  # page (GET) with `account_ids[]` query params. An empty selection means "all
  # accounts" (no filter). The trigger button shows how many accounts are selected.
  #
  # Usage:
  #   render UI::AccountFilter.new(
  #     accounts: Current.user.finance_accounts.visible,
  #     selected_ids: filter_account_ids,
  #     url: root_path,
  #     extra_params: { period: @period.key }
  #   )

  attr_reader :accounts, :selected_ids, :url, :extra_params

  def initialize(accounts:, selected_ids:, url:, extra_params: {})
    @accounts = accounts
    @selected_ids = Array(selected_ids).map(&:to_s)
    @url = url
    @extra_params = extra_params || {}
  end

  def trigger_label
    if selected_ids.any?
      I18n.t("UI.account_filter.accounts_selected", count: selected_ids.size)
    else
      I18n.t("UI.account_filter.all_accounts")
    end
  end

  def filtered?
    selected_ids.any?
  end

  def selected?(account)
    selected_ids.include?(account.id.to_s)
  end

  def grouped_accounts
    accounts.group_by { |a| a.accountable_type }
  end

  def group_label(accountable_type)
    I18n.t("activerecord.models.#{accountable_type.underscore}", default: accountable_type.humanize)
  end

  def clear_url
    if extra_params.any?
      "#{url}?#{extra_params.to_query}"
    else
      url
    end
  end
end
