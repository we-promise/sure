class UI::Account::ActivityDate < ApplicationComponent
  attr_reader :account, :data

  delegate :date, :entries, :balance, :projected_balance_money, :transfers, :split_parents, to: :data

  def initialize(account:, data:)
    @account = account
    @data = data
  end

  def id
    dom_id(account, "entries_#{date}")
  end

  def broadcast_channel
    account
  end

  # Scheduled (future-dated) entries have no Balance row yet -- see
  # Entry#scheduled?. `projected_balance_money` estimates one from the
  # account's current balance plus scheduled entries through this date.
  # `account.balance_money` is a last-resort fallback for a non-scheduled
  # date that somehow has neither (e.g. before the first sync completes).
  def end_balance_money
    balance&.end_balance_money || projected_balance_money || account.balance_money
  end

  def projected?
    balance.nil? && projected_balance_money.present?
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
