module Retirement
  module Fire
    # Normalised inputs to the forecast stepper. All money is in the plan's
    # currency / today's money; real_return is the inflation-adjusted rate
    # as a fraction (0.05 = 5%). Keeping this a plain value object lets the
    # math be unit-tested without a persisted Goal::Retirement.
    Inputs = Data.define(
      :current_age,
      :retire_age,
      :terminal_age,
      :real_return,
      :annual_savings,
      :annual_target_spend,
      :starting_portfolio,
      :retire_year,
      :payouts,
      :target_adjustments
    )
  end
end
