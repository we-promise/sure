class BasisTrade::LiveSnapshotBuilder
  Result = Struct.new(:configured, :snapshot, :error, keyword_init: true)

  def initialize(family:)
    @family = family
  end

  def call
    return Result.new(configured: false) unless @family.basis_trade_sources_configured?

    snapshot = {
      recorded_at: Time.current,
      currency: @family.primary_currency_code,
      spot_leg_cents: 0,
      short_leg_cents: 0,
      funding_accrued_cents: 0,
      rewards_accrued_cents: 0,
      metadata: {}
    }

    if @family.basis_long_address.present?
      spot_leg = BasisTrade::OptimismWalletValuator.new.value(
        address: @family.basis_long_address,
        token_addresses: @family.basis_long_token_addresses_array
      )
      snapshot[:spot_leg_cents] = dollars_to_cents(spot_leg[:total_value])
      snapshot[:metadata][:spot_tokens] = spot_leg[:tokens]
    end

    if @family.basis_lighter_address.present?
      lighter_summary = Provider::Lighter.new.total_account_value_for_l1_address(@family.basis_lighter_address)
      snapshot[:short_leg_cents] = dollars_to_cents(lighter_summary[:total_account_value])
      snapshot[:metadata][:lighter] = lighter_summary
    end

    Result.new(configured: true, snapshot: snapshot)
  rescue StandardError => error
    Result.new(configured: true, error: error.message)
  end

  private

    def dollars_to_cents(value)
      (BigDecimal(value.to_s) * 100).round(0).to_i
    end
end
