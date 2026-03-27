# frozen_string_literal: true

class CoinstatsItem::ExchangeLinker
  Result = Struct.new(:success?, :created_count, :errors, keyword_init: true)

  attr_reader :coinstats_item, :connection_id, :connection_fields, :name

  def initialize(coinstats_item, connection_id:, connection_fields:, name: nil)
    @coinstats_item = coinstats_item
    @connection_id = connection_id
    @connection_fields = connection_fields.to_h.compact_blank
    @name = name
  end

  def link
    return Result.new(success?: false, created_count: 0, errors: [ "Exchange is required" ]) if connection_id.blank?
    return Result.new(success?: false, created_count: 0, errors: [ "Exchange credentials are required" ]) if connection_fields.blank?

    created_count = 0
    exchange = fetch_exchange_definition
    validate_required_fields!(exchange)

    response = provider.connect_portfolio_exchange(
      connection_id: connection_id,
      connection_fields: connection_fields,
      name: name.presence || default_portfolio_name(exchange)
    )

    unless response.success?
      return Result.new(success?: false, created_count: 0, errors: [ response.error.message ])
    end

    payload = response.data.with_indifferent_access
    portfolio_id = payload[:portfolioId]
    raise Provider::Coinstats::Error, "CoinStats did not return a portfolioId" if portfolio_id.blank?

    coins = provider.list_portfolio_coins(portfolio_id: portfolio_id)

    ActiveRecord::Base.transaction do
      coinstats_item.update!(
        exchange_connection_id: connection_id,
        exchange_portfolio_id: portfolio_id,
        institution_id: connection_id,
        institution_name: exchange[:name],
        raw_institution_payload: exchange
      )

      coinstats_account = upsert_exchange_account!(coins, exchange, portfolio_id)
      created_count = ensure_local_account!(coinstats_account) ? 1 : 0
    end

    coinstats_item.sync_later

    Result.new(success?: true, created_count: created_count, errors: [])
  rescue Provider::Coinstats::Error, ArgumentError => e
    Result.new(success?: false, created_count: 0, errors: [ e.message ])
  end

  private

    def provider
      @provider ||= Provider::Coinstats.new(coinstats_item.api_key)
    end

    def fetch_exchange_definition
      exchange = provider.exchange_options.find { |option| option[:connection_id] == connection_id }
      raise ArgumentError, "Unsupported exchange connection: #{connection_id}" unless exchange

      exchange
    end

    def validate_required_fields!(exchange)
      missing_fields = Array(exchange[:connection_fields]).filter_map do |field|
        key = field[:key].to_s
        field[:name] if key.blank? || connection_fields[key].blank?
      end

      return if missing_fields.empty?

      raise ArgumentError, "Missing required exchange fields: #{missing_fields.join(', ')}"
    end

    def default_portfolio_name(exchange)
      "#{exchange[:name]} Portfolio"
    end

    def upsert_exchange_account!(coins, exchange, portfolio_id)
      account_name = name.presence || exchange[:name]
      coinstats_account = coinstats_item.coinstats_accounts.find_or_initialize_by(
        account_id: portfolio_account_id(portfolio_id),
        wallet_address: portfolio_id
      )

      coinstats_account.name = account_name
      coinstats_account.provider = exchange[:name]
      coinstats_account.account_status = "active"
      coinstats_account.wallet_address = portfolio_id
      coinstats_account.institution_metadata = {
        logo: exchange[:icon],
        exchange_logo: exchange[:icon]
      }.compact
      coinstats_account.raw_payload = build_snapshot(coins, exchange, portfolio_id, account_name)
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

    def build_snapshot(coins, exchange, portfolio_id, account_name)
      {
        source: "exchange",
        portfolio_account: true,
        portfolio_id: portfolio_id,
        connection_id: exchange[:connection_id],
        exchange_name: exchange[:name],
        id: portfolio_account_id(portfolio_id),
        name: account_name,
        institution_logo: exchange[:icon],
        coins: Array(coins).map(&:to_h)
      }
    end

    def portfolio_account_id(portfolio_id)
      "exchange_portfolio:#{portfolio_id}"
    end
end
