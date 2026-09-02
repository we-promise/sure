module LoansHelper
  def loan_leverage_band_class(band)
    {
      conservative: "text-success",
      moderate: "text-accent",
      high: "text-destructive"
    }.fetch(band)
  end
end
