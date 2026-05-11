# frozen_string_literal: true

module BrexItemsHelper
  BrexAccountDisplay = Struct.new(
    :id,
    :name,
    :kind,
    :currency,
    :status,
    :blank_name,
    keyword_init: true
  ) do
    alias_method :blank_name?, :blank_name
  end

  def brex_account_display(account)
    data = account.with_indifferent_access
    kind = BrexAccount.kind_for(data)
    name = BrexAccount.name_for(data)

    BrexAccountDisplay.new(
      id: data[:id],
      name: name,
      kind: kind,
      currency: BrexAccount.currency_code_from_money(data[:current_balance] || data[:available_balance] || data[:account_limit]),
      status: data[:status],
      blank_name: name.blank?
    )
  end

  def brex_account_metadata(display)
    parts = [
      t("brex_items.account_metadata.provider"),
      display.currency,
      translated_brex_metadata_value("kinds", display.kind),
      translated_brex_metadata_value("statuses", display.status)
    ].compact

    parts.join(t("brex_items.account_metadata.separator"))
  end

  def brex_item_render_locals(brex_item, sync_stats_map: nil, account_counts_map: nil, institutions_count_map: nil)
    counts = (account_counts_map || {})[brex_item.id] || {}

    {
      brex_item: brex_item,
      stats: (sync_stats_map || {})[brex_item.id] || brex_item.syncs.ordered.first&.sync_stats || {},
      unlinked_count: counts[:unlinked] || brex_item.unlinked_accounts_count,
      linked_count: counts[:linked] || brex_item.linked_accounts_count,
      total_count: counts[:total] || brex_item.total_accounts_count,
      institutions_count: (institutions_count_map || {})[brex_item.id] || brex_item.connected_institutions.size
    }
  end

  def default_brex_depository_subtype(account_name)
    normalized_name = account_name.to_s.downcase

    if normalized_name.match?(/\bchecking\b|\bchequing\b|\bck\b|demand\s+deposit/)
      "checking"
    elsif normalized_name.match?(/\bsavings\b|\bsv\b/)
      "savings"
    elsif normalized_name.match?(/money\s+market|\bmm\b/)
      "money_market"
    else
      "checking"
    end
  end

  private
    def translated_brex_metadata_value(scope, value)
      key = value.to_s
      return nil if key.blank?

      t("brex_items.#{scope}.#{key}", default: key.titleize)
    end
end
