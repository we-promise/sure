module LoansHelper
  def loan_leverage_band_class(band)
    {
      conservative: "text-success",
      moderate: "text-warning",
      high: "text-destructive"
    }.fetch(band)
  end
end
