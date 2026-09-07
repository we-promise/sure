class LoanScenario < ApplicationRecord
  # A named "what if" on a loan: extra repayments, and optionally an assumed
  # offset balance or a rate override.
  #
  # Scenarios are SHARED HOUSEHOLD ARTIFACTS (F7). A mortgage is a joint
  # object, and anyone who can see the loan can edit or delete any scenario on
  # it. `created_by_user` is attribution and display only -- it must never be
  # read as access control, or two people modelling the same mortgage together
  # end up locked out of each other's drafts.
  #
  # Results are LIVE ESTIMATES, never snapshots. They recompute against the
  # loan's current balance, rate and offset on every view: a scenario pinned to
  # a stale balance is worse than useless, because its whole value is answering
  # "given where I am now, what if...". The simulation result is deliberately
  # not persisted; `calculator_version` and `last_calculated_at` are, so
  # support can tell which engine produced a figure a user is quoting.
  MAX_PER_LOAN = 5
  SLOTS = (0...MAX_PER_LOAN).to_a.freeze

  belongs_to :loan
  belongs_to :created_by_user, class_name: "User", optional: true
  has_many :extra_repayments, class_name: "LoanExtraRepayment", dependent: :destroy

  validates :name, presence: true, length: { maximum: 100 }
  validates :currency, presence: true
  validates :slot, inclusion: { in: SLOTS }
  validates :calculator_version, presence: true
  validates :rate_override, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 100 }, allow_nil: true
  validates :assumed_offset_balance, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true

  # Deliberately NOT `validates_uniqueness_of :name`: accounts are shared per
  # user through `account_shares`, so two housemates can both see one loan, and
  # a unique name would turn a cosmetic collision into an error.

  before_validation :assign_defaults, on: :create

  # Creates a scenario in the lowest free slot.
  #
  # The cap is enforced by the unique `(loan_id, slot)` index, not by counting.
  # Counting rows and comparing to five is exactly the race the structural cap
  # exists to close: two concurrent creates both read four, both write, and the
  # loan ends up with six. Here the loser of that race hits the index and is
  # translated into a clean rejection (gate G5).
  def self.create_in_free_slot(loan:, attributes: {})
    scenario = new(attributes.merge(loan: loan))
    scenario.slot = loan.loan_scenarios.pluck(:slot).then { |taken| (SLOTS - taken).min }

    if scenario.slot.nil?
      scenario.errors.add(:base, :slot_cap_reached)
      return scenario
    end

    begin
      scenario.save
    rescue ActiveRecord::RecordNotUnique
      # Another request took this slot between our read and our write. That is
      # the cap doing its job, not an error to retry blindly.
      scenario.errors.add(:base, :slot_cap_reached)
    end

    scenario
  end

  def creator_name
    created_by_user&.display_name || created_by_user&.email
  end

  private

    def assign_defaults
      self.currency ||= loan&.account&.currency
      self.calculator_version ||= Loan::AmortizationSchedule::ALGORITHM_VERSION
    end
end
