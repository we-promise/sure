# Something a retirement plan spends or receives over a span of calendar years.
# The simulation reads these as RetirementPlan::Simulation::Stream.
#
# expense: recurring spending, drawn from the portfolio once retired.
# income:  a pension or similar, set against that spending once retired.
# one_off: a single amount out of the portfolio in its start year.
class RetirementPlan::Stream < ApplicationRecord
  KINDS = %w[expense income one_off].freeze
  SOURCES = %w[seeded_living_costs seeded_loan manual].freeze

  belongs_to :retirement_plan
  # The loan a seeded repayment came from. Kept when the account goes: the
  # user may have edited the stream since.
  belongs_to :account, optional: true

  validates :name, presence: true
  validates :kind, inclusion: { in: KINDS }
  validates :source, inclusion: { in: SOURCES }
  validates :annual_amount, numericality: { greater_than: 0 }
  validates :start_year, :end_year, numericality: { only_integer: true }, allow_nil: true
  validate :ends_no_earlier_than_it_starts

  def to_simulation_stream
    RetirementPlan::Simulation::Stream.new(kind:, annual_amount:, start_year:, end_year:, indexed:)
  end

  private
    def ends_no_earlier_than_it_starts
      return if start_year.blank? || end_year.blank? || end_year >= start_year

      errors.add(:end_year, :greater_than_or_equal_to, count: start_year)
    end
end
