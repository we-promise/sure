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
      I18n.t("valuations.names.opening_anchor.#{accountable_type.underscore}", default: "Opening balance")
    end

    def current_anchor_name
      I18n.t("valuations.names.current_anchor.#{accountable_type.underscore}", default: "Current balance")
    end

    def recon_name
      I18n.t("valuations.names.recon.#{accountable_type.underscore}", default: "Manual balance update")
    end
end