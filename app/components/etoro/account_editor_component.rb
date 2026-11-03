class Etoro::AccountEditorComponent < ApplicationComponent
  def initialize(items: nil, family:)
    @items = items || family.etoro_items.ordered
    @family = family
    @account_counts_by_item_id = preload_account_counts
  end

  attr_reader :items

  def new_item
    @new_item ||= @family.etoro_items.build
  end

  def sync_status_summary_for(item)
    counts = @account_counts_by_item_id.fetch(item.id, { total: 0, linked: 0, unlinked: 0 })

    if counts[:total].zero?
      I18n.t("etoro_items.sync_status.no_accounts")
    elsif counts[:unlinked].zero?
      I18n.t("etoro_items.sync_status.all_linked", count: counts[:linked])
    else
      I18n.t("etoro_items.sync_status.partial", linked: counts[:linked], unlinked: counts[:unlinked])
    end
  end

  def translation(key, **options)
    helpers.t("settings.providers.etoro_panel.#{key}", **options)
  end

  private

    def preload_account_counts
      item_ids = items.map(&:id).compact
      return {} if item_ids.empty?

      EtoroAccount
        .left_joins(:account_provider)
        .where(etoro_item_id: item_ids)
        .group(:etoro_item_id)
        .pluck(
          :etoro_item_id,
          Arel.sql("COUNT(etoro_accounts.id)"),
          Arel.sql("COUNT(account_providers.id)")
        )
        .each_with_object({}) do |(item_id, total, linked), counts|
          counts[item_id] = {
            total: total,
            linked: linked,
            unlinked: total - linked
          }
        end
    end
end
