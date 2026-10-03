class UI::Account::ActivityFeed < ApplicationComponent
  attr_reader :feed_data, :pagy, :search, :compact, :group_by_date, :running_balances, :q

  def initialize(feed_data:, pagy:, search: nil, compact: false, group_by_date: true, running_balances: {}, q: {})
    @feed_data = feed_data
    @pagy = pagy
    @search = search
    @compact = compact
    @group_by_date = group_by_date
    @running_balances = running_balances || {}
    @q = q || {}
  end

  def filtered?
    q.present? && q.values.any? { |v| v.present? && (v.is_a?(Array) ? v.any?(&:present?) : true) }
  end

  def compact?
    !!@compact
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

  private
    def account
      feed_data.account
    end
end
