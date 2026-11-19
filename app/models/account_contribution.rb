# Money put into or taken out of an investment account from outside it:
# employee and employer contributions, rollovers, transfers and withdrawals.
# The running total of these is the account's principal; the rest of the
# balance is earnings (see Account::PrincipalSummary).
#
# Kept apart from entries on purpose: these records never change the account's
# balance history. Many retirement accounts only have balance snapshots, and
# their contribution history comes from statements uploaded later.
class AccountContribution < ApplicationRecord
  include Monetizable

  KINDS = %w[contribution employer_contribution rollover transfer_in withdrawal transfer_out].freeze
  OUTFLOW_KINDS = %w[withdrawal transfer_out].freeze
  SOURCES = %w[manual csv statement].freeze

  belongs_to :account
  belongs_to :account_statement, optional: true

  enum :kind, KINDS.index_by(&:itself), validate: true
  enum :source, SOURCES.index_by(&:itself), validate: true, prefix: :from

  monetize :amount, :principal_amount

  before_validation :normalize

  validates :date, :amount, :currency, presence: true
  validate :amount_not_zero

  scope :chronological, -> { order(:date, :created_at) }

  # The part of this record that counts toward principal.
  def principal_value
    principal_amount.presence || amount
  end

  def outflow?
    amount.negative?
  end

  private
    def normalize
      self.currency ||= account&.currency
      return if amount.nil?

      # Withdrawals and transfers out reduce principal whatever sign was typed.
      if OUTFLOW_KINDS.include?(kind)
        self.amount = -amount.abs
        self.principal_amount = -principal_amount.abs if principal_amount.present?
      elsif amount.negative? && kind.in?(%w[contribution employer_contribution])
        self.kind = "withdrawal"
      end
    end

    def amount_not_zero
      errors.add(:amount, :other_than, count: 0) if amount.present? && amount.zero?
    end
end
