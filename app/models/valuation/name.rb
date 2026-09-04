class Valuation::Name
  def initialize(valuation_kind, accountable_type)
    @valuation_kind = valuation_kind
    @accountable_type = accountable_type
  end

  # Returns the stable English name persisted for this valuation type.
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

  # Returns the I18n key suffix for this valuation type and account type.
  def translation_key
    case valuation_kind
    when "opening_anchor"
      opening_anchor_translation_key
    when "current_anchor"
      current_anchor_translation_key
    else
      reconciliation_translation_key
    end
  end

  private
    attr_reader :valuation_kind, :accountable_type

    # Selects the persisted name for an opening balance valuation.
    def opening_anchor_name
      case accountable_type
      when "Property", "Vehicle"
        "Original purchase price"
      when "Loan"
        "Original principal"
      when "Investment", "Crypto", "OtherAsset"
        "Opening account value"
      else
        "Opening balance"
      end
    end

    # Selects the persisted name for a provider-managed current valuation.
    def current_anchor_name
      case accountable_type
      when "Property", "Vehicle"
        "Current market value"
      when "Loan"
        "Current loan balance"
      when "Investment", "Crypto", "OtherAsset"
        "Current account value"
      else
        "Current balance"
      end
    end

    # Selects the persisted name for a manual reconciliation valuation.
    def recon_name
      case accountable_type
      when "Property", "Investment", "Vehicle", "Crypto", "OtherAsset"
        "Manual value update"
      when "Loan"
        "Manual principal update"
      else
        "Manual balance update"
      end
    end

    # Selects the translation key for an opening balance valuation.
    def opening_anchor_translation_key
      case accountable_type
      when "Property", "Vehicle" then :original_purchase_price
      when "Loan" then :original_principal
      when "Investment", "Crypto", "OtherAsset" then :opening_account_value
      else :opening_balance
      end
    end

    # Selects the translation key for a provider-managed current valuation.
    def current_anchor_translation_key
      case accountable_type
      when "Property", "Vehicle" then :current_market_value
      when "Loan" then :current_loan_balance
      when "Investment", "Crypto", "OtherAsset" then :current_account_value
      else :current_balance
      end
    end

    # Selects the translation key for a manual reconciliation valuation.
    def reconciliation_translation_key
      case accountable_type
      when "Property", "Investment", "Vehicle", "Crypto", "OtherAsset" then :manual_value_update
      when "Loan" then :manual_principal_update
      else :manual_balance_update
      end
    end
end
