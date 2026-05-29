# Static effective "net rate" (fraction of gross pension income KEPT after
# tax) used by the v1 retirement forecast. This is a deliberate v1
# approximation; v2 swaps in a per-country bracket engine behind the same
# Retirement::Tax::StaticRate.net_rate interface.
#
# de_renten is handled separately (keyed on retirement year) in
# Retirement::Tax::StaticRate, because the German Besteuerungsanteil rises
# with cohort. The flat rates below are documented single-number
# approximations for the other treatments.
RETIREMENT_TAX_STATIC = {
  "de_bav" => 0.74,
  "de_riester" => 0.85,
  "de_private" => 0.74,
  "uk_state" => 0.92,
  "uk_dc_drawdown" => 0.85,
  "uk_dc_25pct" => 1.00,
  "uk_isa" => 1.00,
  "custom_post_tax" => 1.00
}.freeze

# Cross-check the table against the PensionSource enum at boot so a new
# tax_treatment can't ship without a rate. de_renten is intentionally not
# in the flat table (computed per-year), so it is excluded here.
Rails.application.config.after_initialize do
  expected = PensionSource::TAX_TREATMENTS - [ "de_renten" ]
  missing = expected - RETIREMENT_TAX_STATIC.keys
  if missing.any?
    raise "RETIREMENT_TAX_STATIC missing net rates for: #{missing.join(', ')}"
  end
rescue NameError
  # PensionSource not loaded yet (e.g. asset precompile); skip the check.
end
