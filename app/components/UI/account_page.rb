class UI::AccountPage < ApplicationComponent
  attr_reader :account, :chart_view, :chart_period

  renders_one :activity_feed, ->(feed_data:, pagy:, search:) { UI::Account::ActivityFeed.new(feed_data: feed_data, pagy: pagy, search: search) }

  def initialize(account:, chart_view: nil, chart_period: nil, active_tab: nil)
    @account = account
    @chart_view = chart_view
    @chart_period = chart_period
    @active_tab = active_tab
  end

  def id
    dom_id(account, :container)
  end

  def broadcast_channel
    account
  end

  def broadcast_refresh!
    Turbo::StreamsChannel.broadcast_replace_to(broadcast_channel, target: id, renderable: self, layout: false)
  end

  def title
    account.name
  end

  def subtitle
    return nil unless account.property?

    account.property.address
  end

  def active_tab
    tabs.find { |tab| tab == @active_tab&.to_sym } || tabs.first
  end

  def tabs
    case account.accountable_type
    when "Investment", "Crypto"
      [ :activity, :holdings ]
    when "Property", "Vehicle", "Loan"
      [ :activity, :overview ]
    else
      [ :activity ]
    end
  end

  def fx_coverage_start_date
    return nil if account.family.nil?
    return nil if account.currency == account.family.currency

    pair = ExchangeRatePair.find_by(from_currency: account.currency, to_currency: account.family.currency)
    return nil if pair.nil? || pair.first_provider_rate_on.nil?

    oldest_entry = account.entries.minimum(:date)
    return nil if oldest_entry.nil? || oldest_entry >= pair.first_provider_rate_on

    pair.first_provider_rate_on
  end

  def tab_content_for(tab)
    case tab
    when :activity
      activity_feed
    when :holdings, :overview
      # Accountable is responsible for implementing the partial in the correct folder
      render "#{account.accountable_type.downcase.pluralize}/tabs/#{tab}", account: account
    end
  end
end
