# frozen_string_literal: true

# Component to display installment overview with progress, next payment, and breakdown.
#
# @example Basic usage
#   <%= render Installments::OverviewComponent.new(installment: @account.installment) %>
#
class Installments::OverviewComponent < ViewComponent::Base
  attr_reader :installment

  # @param installment [Installment] The installment record to display
  def initialize(installment:)
    @installment = installment
  end

  def render?
    installment.present?
  end

  # Returns the progress percentage (0-100) of completed payments
  def progress_percentage
    return 0 if installment.total_term.zero?
    (installment.payments_completed.to_f / installment.total_term * 100).round
  end

  # Returns the total amount paid so far
  def total_paid
    installment.payments_completed * installment.installment_cost
  end

  # Returns the remaining balance
  def remaining
    installment.calculate_current_balance
  end

  # Returns the currency for the installment (from account)
  def currency
    installment.account.currency
  end
end
