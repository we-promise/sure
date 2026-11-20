# frozen_string_literal: true

class RevolutXAccount::HoldingsProcessor
  def initialize(revolut_x_account)
    @revolut_x_account = revolut_x_account
  end

  def process
    return unless account&.accountable_type == "Crypto"

    imported_tickers = crypto_assets.filter_map { |asset| process_asset(asset)&.ticker }
    zero_absent_holdings(imported_tickers)
  end

  private

    attr_reader :revolut_x_account

    def account
      revolut_x_account.current_account
    end

    def currency
      revolut_x_account.revolut_x_item.family.currency
    end

    def crypto_assets
      revolut_x_account.raw_payload.to_h.fetch("assets", []).select { |asset| asset["kind"] == "crypto" }
    end

    # Staked and reserved units are still owned, so the holding is the total.
    # Returns the security when a holding was written, else nil.
    def process_asset(asset)
      symbol = asset["symbol"]
      quantity = asset["total"].to_d
      return if quantity.zero?

      security = Onchain::SecurityResolver.resolve(symbol: symbol, name: asset["name"]) if asset["price_usd"].present?
      unless security
        revolut_x_account.report_unvalued_asset(symbol, source: self.class.name)
        return
      end

      price = Money.new(asset["price_usd"].to_d, "USD").exchange_to(currency).amount

      import_adapter.import_holding(
        security: security,
        quantity: quantity,
        amount: quantity * price,
        currency: currency,
        date: Date.current,
        price: price,
        cost_basis: nil,
        external_id: "revolut_x_#{symbol}_#{Date.current}",
        account_provider_id: revolut_x_account.account_provider&.id,
        source: "revolut_x",
        delete_future_holdings: false
      )
      security
    end

    # Any coin without a holding written this run (gone from the payload, or
    # held but unpriced) gets a today-dated zero, so its last provider snapshot
    # stops counting while the balance values it at 0.
    def zero_absent_holdings(present_tickers)
      # No assets array means no snapshot, not an empty account.
      return unless revolut_x_account.raw_payload.to_h["assets"].is_a?(Array)

      provider_link = revolut_x_account.account_provider
      return unless provider_link

      held_security_ids = account.holdings.where(account_provider_id: provider_link.id)
        .distinct.pluck(Arel.sql("COALESCE(provider_security_id, security_id)"))

      Security.where(id: held_security_ids).where.not(ticker: present_tickers).find_each do |security|
        import_adapter.import_holding(
          security: security,
          quantity: 0,
          amount: 0,
          currency: currency,
          date: Date.current,
          price: 0,
          cost_basis: nil,
          external_id: "revolut_x_#{security.ticker.delete_prefix(Onchain::SecurityResolver::TICKER_PREFIX)}_#{Date.current}",
          account_provider_id: provider_link.id,
          source: "revolut_x",
          delete_future_holdings: false
        )
      end
    end

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end
end
