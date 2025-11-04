# SimpleFin Credit Card processor for liability-specific features
class SimplefinAccount::Liabilities::CreditProcessor
  def initialize(simplefin_account)
    @simplefin_account = simplefin_account
  end

  def process
    return unless simplefin_account.current_account&.accountable_type == "CreditCard"

    # Update credit card specific attributes if available
    update_credit_attributes
  end

  private
    attr_reader :simplefin_account

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def account
      simplefin_account.current_account
    end

    def update_credit_attributes
      # SimpleFin provides available_balance which could be credit limit for cards
      available_balance = simplefin_account.raw_payload&.dig("available-balance")

      if available_balance.present?
        credit_limit = parse_decimal(available_balance)
        if credit_limit > 0
          import_adapter.update_accountable_attributes(
            attributes: { available_credit: credit_limit },
            source: "simplefin"
          )
        end
      end
    end

    def parse_decimal(value)
      return 0 unless value.present?

      case value
      when String
        BigDecimal(value)
      when Numeric
        BigDecimal(value.to_s)
      else
        BigDecimal("0")
      end
    rescue ArgumentError => e
      Rails.logger.error "Failed to parse SimpleFin credit value #{value}: #{e.message}"
      BigDecimal("0")
    end
end
