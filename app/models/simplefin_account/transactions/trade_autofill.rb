require "bigdecimal"

class SimplefinAccount::Transactions::TradeAutofill
  DESCRIPTION = /\bbuy\s+(?<quantity>\d+(?:\.\d+)?)\s+shares?\s+of\s+(?<company>.+?)\s+for\s+\$?(?<price>\d+(?:\.\d+)?)\s+each\b/i.freeze
  AMOUNT_TOLERANCE = BigDecimal("0.02")
  SOURCE = "simplefin_trade_autofill"

  class << self
    def enabled?
      Rails.configuration.x.simplefin.trade_autofill_enabled == true
    end

    def parse(text)
      match = DESCRIPTION.match(text.to_s)
      return nil unless match

      {
        company: match[:company].strip,
        quantity: BigDecimal(match[:quantity]),
        price: BigDecimal(match[:price])
      }
    rescue ArgumentError
      nil
    end

    def amount_matches?(parsed, amount)
      expected = parsed.fetch(:quantity) * parsed.fetch(:price)
      (expected - BigDecimal(amount.to_s).abs).abs <= AMOUNT_TOLERANCE
    rescue ArgumentError, TypeError
      false
    end

    def convert(entry)
      return unless enabled?
      return unless entry&.entryable.is_a?(Transaction)
      return unless entry.source == "simplefin"
      return if entry.protected_from_sync?
      return unless entry.account.investment?
      return unless entry.transaction.kind == "standard"
      return if entry.transaction.investment_activity_label.present?

      parsed = parse(entry.name)
      return unless parsed && amount_matches?(parsed, entry.amount)

      external_id = "simplefin_trade_autofill:#{entry.external_id}"
      return if entry.account.entries.exists?(external_id: external_id, source: SOURCE)

      security = resolve_security(parsed.fetch(:company))
      return unless security

      Entry.transaction do
        return if entry.account.entries.exists?(external_id: external_id, source: SOURCE)

        trade_entry = entry.account.entries.create!(
          external_id: external_id,
          source: SOURCE,
          name: Trade.build_name("buy", parsed.fetch(:quantity), security.ticker),
          date: entry.date,
          amount: entry.amount.abs,
          currency: entry.currency,
          notes: "Auto-converted from SimpleFIN transaction #{entry.id}: #{entry.name}",
          entryable: Trade.new(
            security: security,
            qty: parsed.fetch(:quantity),
            price: parsed.fetch(:price),
            currency: entry.currency,
            investment_activity_label: "Buy"
          )
        )
        trade_entry.lock_saved_attributes!
        trade_entry.mark_user_modified!
        entry.update!(excluded: true)
      end
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
      Rails.logger.warn("SimpleFIN trade autofill skipped entry #{entry&.id}: #{e.message}")
      nil
    end

    private

      def resolve_security(company)
        normalized = company.strip
        Security
          .where("UPPER(ticker) = :value OR LOWER(name) = :name", value: normalized.upcase, name: normalized.downcase)
          .order(:created_at)
          .first
      end
  end
end
