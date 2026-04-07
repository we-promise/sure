# frozen_string_literal: true

class CoinstatsAccount::HoldingsProcessor
  def initialize(coinstats_account)
    @coinstats_account = coinstats_account
  end

  def process
    return unless account&.crypto?

    coinstats_account.exchange_portfolio_account? ? process_exchange_portfolio_holdings : process_single_asset_holding
  end

  private
    attr_reader :coinstats_account

    def account
      coinstats_account.current_account
    end

    def account_provider
      coinstats_account.account_provider
    end

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def process_single_asset_holding
      return if coinstats_account.fiat_asset?

      quantity = coinstats_account.asset_quantity
      return if quantity.zero?

      security = resolve_security(coinstats_account.asset_symbol, coinstats_account.asset_name)
      return unless security

      import_adapter.import_holding(
        security: security,
        quantity: quantity.abs,
        amount: coinstats_account.inferred_current_balance,
        currency: coinstats_account.inferred_currency,
        date: holding_date,
        price: coinstats_account.asset_price,
        cost_basis: coinstats_account.average_buy_price,
        external_id: single_asset_external_id,
        account_provider_id: account_provider&.id,
        source: "coinstats",
        delete_future_holdings: false
      )
    end

    def process_exchange_portfolio_holdings
      return if account_provider.blank?

      active_coins = coinstats_account.portfolio_non_fiat_coins.reject { |coin| coinstats_account.asset_quantity(coin).zero? }
      target_currency = coinstats_account.inferred_currency
      cleanup_stale_holdings!(active_coins.map { |coin| portfolio_external_id(coin) })

      active_coins.each do |coin|
        security = resolve_security(asset_symbol(coin), asset_name(coin))
        next unless security

        quantity = coinstats_account.asset_quantity(coin).abs
        next if quantity.zero?

        import_adapter.import_holding(
          security: security,
          quantity: quantity,
          amount: coinstats_account.current_value_for_coin(coin, currency: target_currency),
          currency: target_currency,
          date: holding_date,
          price: coinstats_account.asset_price(coin, currency: target_currency),
          cost_basis: coinstats_account.average_buy_price(coin, currency: target_currency),
          external_id: portfolio_external_id(coin),
          account_provider_id: account_provider.id,
          source: "coinstats",
          delete_future_holdings: false
        )
      end
    end

    def cleanup_stale_holdings!(external_ids)
      scope = account.holdings.where(account_provider_id: account_provider.id, date: holding_date)

      if external_ids.any?
        scope.where.not(external_id: external_ids).delete_all
      else
        scope.delete_all
      end
    end

    def resolve_security(symbol, name)
      return if symbol.blank?

      ticker = symbol.start_with?("CRYPTO:") ? symbol : "CRYPTO:#{symbol}"
      security = Security::Resolver.new(ticker).resolve
      return unless security

      updates = {}
      updates[:name] = name if security.name.blank? && name.present?
      updates[:offline] = true if security.respond_to?(:offline=) && security.offline != true
      security.update!(updates) if updates.any?
      security
    rescue => e
      Rails.logger.warn("CoinstatsAccount::HoldingsProcessor - Failed to resolve #{symbol}: #{e.class} - #{e.message}")
      nil
    end

    def asset_symbol(payload)
      coinstats_account.asset_symbol(payload)
    end

    def asset_name(payload)
      coinstats_account.asset_name(payload)
    end

    def single_asset_external_id
      "coinstats_holding_#{coinstats_account.account_id}_#{holding_date}"
    end

    def portfolio_external_id(coin_payload)
      coin_payload = coin_payload.to_h.with_indifferent_access
      identifier = coin_payload.dig(:coin, :identifier).presence ||
        coin_payload.dig(:coin, :symbol).presence ||
        coin_payload[:coinId].presence ||
        coin_payload[:symbol].presence

      "coinstats_holding_#{coinstats_account.account_id}_#{identifier}_#{holding_date}"
    end

    def holding_date
      Date.current
    end
end
