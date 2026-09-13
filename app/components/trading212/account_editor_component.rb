class Trading212::AccountEditorComponent < ApplicationComponent
  def initialize(items: nil, family:)
    @items = items || family.trading212_items.ordered
    @family = family
    @account_counts_by_item_id = preload_account_counts
  end

  attr_reader :items

  def new_item
    @new_item ||= @family.trading212_items.build
  end

  def sync_status_summary_for(item)
    counts = @account_counts_by_item_id.fetch(item.id, { total: 0, linked: 0, unlinked: 0 })

    if counts[:total].zero?
      I18n.t("trading212_items.sync_status.no_accounts")
    elsif counts[:unlinked].zero?
      I18n.t("trading212_items.sync_status.all_linked", count: counts[:linked])
    else
      I18n.t("trading212_items.sync_status.partial", linked: counts[:linked], unlinked: counts[:unlinked])
    end
  end

  def environment_options
    [
      [ translation("environment_live"), "live" ],
      [ translation("environment_demo"), "demo" ]
    ]
  end

  def currency_options
    Money::Currency.as_options.map { |currency| [ "#{currency.name} (#{currency.iso_code})", currency.iso_code ] }
  end

  def translation(key, **options)
    helpers.t("settings.providers.trading212_panel.#{key}", **options)
  end

  private

    def preload_account_counts
      item_ids = items.map(&:id).compact
      return {} if item_ids.empty?

      Trading212Account
        .left_joins(:account_provider)
        .where(trading212_item_id: item_ids)
        .group(:trading212_item_id)
        .pluck(
          :trading212_item_id,
          Arel.sql("COUNT(trading212_accounts.id)"),
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
