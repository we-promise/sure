class UI::Account::ActivityDate < ApplicationComponent
  attr_reader :account, :data, :compact, :group_by_date, :filtered

  delegate :date, :entries, :balance, :transfers, :split_parents, to: :data

  def initialize(account:, data:, compact: false, group_by_date: true, filtered: false)
    @account = account
    @data = data
    @compact = compact
    @group_by_date = group_by_date
    @filtered = filtered
  end

  def compact?
    !!@compact
  end

  def filtered?
    !!@filtered
  end

  def id
    dom_id(account, "entries_#{date}")
  end

  def broadcast_channel
    account
  end

  def end_balance_money
    balance&.end_balance_money || Money.new(0, account.currency)
  end

  def broadcast_refresh!
    Turbo::StreamsChannel.broadcast_replace_to(
      broadcast_channel,
      target: id,
      renderable: self,
      layout: false
    )
  end
end
