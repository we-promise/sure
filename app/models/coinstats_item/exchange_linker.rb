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

    return Result.new(success?: false, created_count: 0, errors: [ response.error.message ]) unless response.success?

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

      if coins.nil?
        Rails.logger.warn "CoinstatsItem::ExchangeLinker - Initial portfolio coin fetch missing for item #{coinstats_item.id} portfolio #{portfolio_id}; deferring local account creation to background sync"
      else
        coinstats_account = exchange_portfolio_account_manager.upsert_account!(
          coins_data: coins,
          portfolio_id: portfolio_id,
          connection_id: exchange[:connection_id],
          exchange_name: exchange[:name],
          account_name: name.presence || exchange[:name],
          institution_logo: exchange[:icon]
        )
        created_count = exchange_portfolio_account_manager.ensure_local_account!(coinstats_account) ? 1 : 0
      end
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

    def exchange_portfolio_account_manager
      @exchange_portfolio_account_manager ||= CoinstatsItem::ExchangePortfolioAccountManager.new(coinstats_item)
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
end
