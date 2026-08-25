class Valuation::Name
  def initialize(valuation_kind, accountable_type)
    @valuation_kind = valuation_kind
    @accountable_type = accountable_type
  end

  def to_s
    case valuation_kind
    when "opening_anchor"
      opening_anchor_name
    when "current_anchor"
      current_anchor_name
    else
      recon_name
    end
  end

  private
    attr_reader :valuation_kind, :accountable_type

    def opening_anchor_name
      case accountable_type
      when "Property", "Vehicle"
        I18n.t("valuations.names.original_purchase_price")
      when "Loan"
        I18n.t("valuations.names.original_principal")
      when "Investment", "Crypto", "OtherAsset"
        I18n.t("valuations.names.opening_account_value")
      else
        I18n.t("valuations.names.opening_balance")
      end
    end

    def current_anchor_name
      case accountable_type
      when "Property", "Vehicle"
        I18n.t("valuations.names.current_market_value")
      when "Loan"
        I18n.t("valuations.names.current_loan_balance")
      when "Investment", "Crypto", "OtherAsset"
        I18n.t("valuations.names.current_account_value")
      else
        I18n.t("valuations.names.current_balance")
      end
    end

    def recon_name
      case accountable_type
      when "Property", "Investment", "Vehicle", "Crypto", "OtherAsset"
        I18n.t("valuations.names.manual_value_update")
      when "Loan"
        I18n.t("valuations.names.manual_principal_update")
      else
        I18n.t("valuations.names.manual_balance_update")
      end
    end
end
