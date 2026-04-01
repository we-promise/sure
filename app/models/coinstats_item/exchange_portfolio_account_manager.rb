# frozen_string_literal: true

class CoinstatsItem::ExchangePortfolioAccountManager
  attr_reader :coinstats_item

  def initialize(coinstats_item)
    @coinstats_item = coinstats_item
  end

  def upsert_account!(coins_data:, portfolio_id:, connection_id:, exchange_name:, account_name:, institution_logo: nil)
    coinstats_account = coinstats_item.coinstats_accounts.find_or_initialize_by(
      account_id: portfolio_account_id(portfolio_id),
      wallet_address: portfolio_id
    )

    coinstats_account.name = account_name
    coinstats_account.provider = exchange_name
    coinstats_account.account_status = "active"
    coinstats_account.wallet_address = portfolio_id
    coinstats_account.institution_metadata = {
      logo: institution_logo,
      exchange_logo: institution_logo
    }.compact
    coinstats_account.raw_payload = build_snapshot(
      coins_data: coins_data,
      portfolio_id: portfolio_id,
      connection_id: connection_id,
      exchange_name: exchange_name,
      account_name: account_name,
      institution_logo: institution_logo
    )
    coinstats_account.currency = coinstats_account.inferred_currency
    coinstats_account.current_balance = coinstats_account.inferred_current_balance
    coinstats_account.save!
    coinstats_account
  end

  def ensure_local_account!(coinstats_account)
    return false if coinstats_account.account.present?

    attributes = {
      family: coinstats_item.family,
      name: coinstats_account.name,
      balance: coinstats_account.current_balance || 0,
      cash_balance: coinstats_account.inferred_cash_balance,
      currency: coinstats_account.currency || coinstats_item.family.currency || "USD",
      accountable_type: "Crypto",
      accountable_attributes: {
        subtype: "exchange",
        tax_treatment: "taxable"
      }
    }

    account = Account.create_and_sync(attributes, skip_initial_sync: true)
    AccountProvider.create!(account: account, provider: coinstats_account)
    true
  end

  def portfolio_account_id(portfolio_id)
    "exchange_portfolio:#{portfolio_id}"
  end

  private
    def build_snapshot(coins_data:, portfolio_id:, connection_id:, exchange_name:, account_name:, institution_logo:)
      {
        source: "exchange",
        portfolio_account: true,
        portfolio_id: portfolio_id,
        connection_id: connection_id,
        exchange_name: exchange_name,
        id: portfolio_account_id(portfolio_id),
        name: account_name,
        institution_logo: institution_logo,
        coins: Array(coins_data).map(&:to_h)
      }
    end
end
