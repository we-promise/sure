class BankBalancesPresenter
  BalanceRow = Struct.new(:key, :observation, keyword_init: true)

  attr_reader :account

  def initialize(account:)
    @account = account
  end

  def render?
    return false unless account.accountable_type == "Depository"

    linked_account = enable_banking_account
    return false unless linked_account
    return false unless currencies_match?(linked_account.currency, account.currency)

    item = linked_account.enable_banking_item
    item.present? && item.family_id == account.family_id
  end

  def snapshot
    return @snapshot if defined?(@snapshot)

    payload = enable_banking_account&.balance_snapshot
    @snapshot = payload.present? ? Provider::BankBalanceSnapshot.new(payload) : nil
  end

  def balance_rows
    rows = [
      BalanceRow.new(key: :booked, observation: observation_for(:booked)),
      BalanceRow.new(key: :available, observation: observation_for(:available))
    ]

    expected = observation_for(:expected)
    rows << BalanceRow.new(key: :expected, observation: expected) if expected.present?
    rows
  end

  def missing_value_key
    fetched_at ? :not_provided : :not_fetched_yet
  end

  def fetched_at
    snapshot&.fetched_at
  end

  def fetched_at_missing_key
    snapshot ? :not_provided : :not_fetched_yet
  end

  def failed?
    snapshot&.failed? == true
  end

  def failure_message_key
    fetched_at.present? ? :latest_fetch_failed_with_saved_values : :latest_fetch_failed_without_saved_values
  end

  def last_attempted_at
    snapshot&.last_attempted_at if failed?
  end

  def expected_balance_used_for_availability?
    snapshot&.available&.mapped_from_expected? == true
  end

  private
    def observation_for(kind)
      observation = snapshot&.public_send(kind)
      observation if observation && currencies_match?(observation.money.currency.iso_code, account.currency)
    end

    def enable_banking_account
      return @enable_banking_account if defined?(@enable_banking_account)

      @enable_banking_account = account.account_providers
        .find_by(provider_type: "EnableBankingAccount")&.provider
    end

    def currencies_match?(left, right)
      left = left.to_s
      right = right.to_s
      left.present? && right.present? && left.casecmp?(right)
    end
end
