# frozen_string_literal: true

# The simple FIRE figures on the Plan page: the FI number, progress towards
# it, and the projected total at retirement.
#
# Formatting only: every figure comes from the RetirementPlan::Projection the
# caller builds with its own `as_of`.
class RetirementPlans::SummaryComponent < ViewComponent::Base
  attr_reader :projection, :currency, :unconverted_count

  def initialize(projection:, currency:, unconverted_count: 0)
    @projection = projection
    @currency = currency
    @unconverted_count = unconverted_count
  end

  def fi_number?
    projection.fi_number.present?
  end

  def money(amount)
    Money.new(amount, currency).format(precision: 0)
  end

  def withdrawal_rate
    helpers.number_to_percentage(projection.safe_withdrawal_rate * 100, precision: 2, strip_insignificant_zeros: true)
  end

  # Whole percent for the figure, which keeps counting past 100 once the user
  # is independent; the bar stops at 100. Both round toward zero, so neither
  # reads 100 before #financially_independent? does, and a sliver below zero
  # reads 0 rather than -1.
  def progress_percent
    (projection.progress * 100).truncate
  end

  def bar_percent
    (projection.bar_progress * 100).floor(1)
  end

  def savings_rate
    helpers.number_to_percentage(projection.effective_savings_rate.to_d * 100, precision: 1, strip_insignificant_zeros: true)
  end

  def savings_rate_derived?
    projection.savings_rate.nil?
  end
end
