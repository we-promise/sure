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

  # The Filter menu offers to show synced balance updates on accounts that
  # hide them by default, once they have any.
  def balance_updates_filter?
    account.hides_balance_updates_by_default? && account.entries.balance_updates.exists?
  end

  private
    def account
      feed_data.account
    end
end
