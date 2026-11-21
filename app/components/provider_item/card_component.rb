# frozen_string_literal: true

# A provider connection's card on the accounts page: its status, its admin
# menu, the accounts the viewer may see, and a prompt to set up new ones.
# Messages come from the provider's own `<key>_items.<key>_item.*` keys. The
# connection model answers `sync_status_summary`, `institution_summary`,
# `connected_institutions` and the linked/unlinked/total account counts; the
# accounts page may pass those counts precomputed per connection.
class ProviderItem::CardComponent < ApplicationComponent
  attr_reader :item, :visible_accounts

  # @param visible_accounts [Array<Account>] the connection's accounts this
  #   viewer may see. Never the connection's own list (#3630).
  def initialize(item:, visible_accounts:, sync_stats_map: nil, account_counts_map: nil, institutions_count_map: nil)
    @item = item
    @visible_accounts = visible_accounts
    @sync_stats_map = sync_stats_map || {}
    @account_counts = (account_counts_map || {})[item.id] || {}
    @institutions_count_map = institutions_count_map || {}
  end

  def provider_key
    item.provider_key
  end

  def stats
    @sync_stats_map[item.id] || item.syncs.ordered.first&.sync_stats || {}
  end

  def unlinked_count
    @account_counts[:unlinked] || item.unlinked_accounts_count
  end

  def linked_count
    @account_counts[:linked] || item.linked_accounts_count
  end

  def total_count
    @account_counts[:total] || item.total_accounts_count
  end

  def institutions_count
    @institutions_count_map[item.id] || item.connected_institutions.size
  end

  # The viewer sees every account on the connection.
  def all_accounts_visible?
    visible_accounts.size == item.accounts.size
  end

  # The viewer may see the connection's institution, its account counts and the
  # account names in its sync summary: anyone who sees every linked account,
  # admin or not, since an admin is not shared every account either (#3630).
  # Before any account is linked there are none to hide, and only an admin,
  # who sets them up, gets the counts.
  def whole_connection_visible?
    return @whole_connection_visible if defined?(@whole_connection_visible)

    @whole_connection_visible = item.accounts.any? ? all_accounts_visible? : Current.user&.admin? == true
  end

  # The title and description of the prompt to set up accounts: for imported
  # accounts nobody has linked yet, or for a connection with no accounts at all.
  # Nil when there is nothing to set up, and for a viewer who cannot set up.
  def setup_prompt
    return unless Current.user&.admin?

    if unlinked_count > 0
      { title: card_t("setup_needed"), description: card_t("setup_description", linked: linked_count, total: total_count) }
    elsif item.accounts.empty? && total_count == 0
      { title: card_t("no_accounts_title"), description: card_t("no_accounts_description") }
    end
  end

  def item_path
    helpers.polymorphic_path(item)
  end

  def sync_path
    helpers.public_send(:"sync_#{provider_key}_item_path", item)
  end

  def setup_accounts_path
    helpers.public_send(:"setup_accounts_#{provider_key}_item_path", item)
  end

  def card_t(key, **options)
    t("#{provider_key}_items.#{provider_key}_item.#{key}", **options)
  end
end
