# frozen_string_literal: true

# Component to display installment payment schedule with status indicators.
#
# @example Basic usage
#   <%= render Installments::PaymentScheduleComponent.new(installment: @account.installment) %>
#
class Installments::PaymentScheduleComponent < ViewComponent::Base
  attr_reader :installment, :schedule

  # @param installment [Installment] The installment record to display
  def initialize(installment:)
    @installment = installment
    @schedule = installment.generate_payment_schedule
  end

  def render?
    installment.present? && schedule.present?
  end

  # Returns the payment status (:completed, :due, or :upcoming)
  def payment_status(payment)
    if payment[:payment_number] <= installment.payments_completed
      :completed
    elsif payment[:date] <= Date.current
      :due
    else
      :upcoming
    end
  end

  # Returns CSS classes for status badge
  def status_classes(status)
    case status
    when :completed
      "bg-green-100 text-green-800"
    when :due
      "bg-yellow-100 text-yellow-800"
    when :upcoming
      "bg-surface-inset text-secondary"
    end
  end

  # Returns the currency for the installment (from account)
  def currency
    installment.account.currency
  end
end
