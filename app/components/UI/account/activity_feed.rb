class UI::Account::ActivityFeed < ApplicationComponent
  attr_reader :feed_data, :pagy, :q

  def initialize(feed_data:, pagy:, q: {})
    @feed_data = feed_data
    @pagy = pagy
    @q = q || {}
  end

  def id
    dom_id(account, :activity_feed)
  end

  def broadcast_channel
    account
  end

  def broadcast_refresh!
    Turbo::StreamsChannel.broadcast_replace_to(
      broadcast_channel,
      target: id,
      renderable: self,
      layout: false
    )
  end

  def activity_dates
    feed_data.entries_by_date
  end

  # Offered on accounts that hide balance updates by default, once they have any.
  def balance_updates_toggle?
    account.hides_balance_updates_by_default? && account.entries.balance_updates.exists?
  end

  def showing_balance_updates?
    helpers.show_balance_updates?
  end

  # Saves the flipped preference and comes back with the same filters.
  # Pagination starts over, since the number of entries changes.
  def balance_updates_toggle_path
    helpers.toggle_balance_updates_account_path(account, q: q.to_h.presence)
  end

  private
    def account
      feed_data.account
    end
end
