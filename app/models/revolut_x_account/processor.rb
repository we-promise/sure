# frozen_string_literal: true

class RevolutXAccount::Processor
  attr_reader :revolut_x_account

  def initialize(revolut_x_account)
    @revolut_x_account = revolut_x_account
  end

  def process
    account = revolut_x_account.current_account
    return unless account

    RevolutXAccount::HoldingsProcessor.new(revolut_x_account).process
    process_account!(account)
    account.ensure_opening_anchor_precedes_entries
  end

  private

    # Fiat at the exchange is cash; the balance is holdings plus that cash,
    # which is the importer's USD total in the family currency. Fiat with no
    # USD rate counts as 0, so it is reported.
    def process_account!(account)
      currency = revolut_x_account.revolut_x_item.family.currency
      fiat = revolut_x_account.raw_payload.to_h.fetch("assets", []).select { |asset| asset["kind"] == "fiat" }
      fiat.each do |asset|
        revolut_x_account.report_unvalued_asset(asset["symbol"], source: self.class.name) if asset["price_usd"].blank?
      end
      fiat_usd = fiat.sum { |asset| asset["amount_usd"].to_d }

      account.update!(
        balance: Money.new(revolut_x_account.current_balance.to_d, "USD").exchange_to(currency).amount,
        cash_balance: Money.new(fiat_usd, "USD").exchange_to(currency).amount,
        currency: currency
      )
    end
end
