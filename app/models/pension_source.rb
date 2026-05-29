class PensionSource < ApplicationRecord
  include Monetizable

  KINDS = %w[state workplace other].freeze
  COUNTRIES = %w[DE US UK].freeze
  PENSION_SYSTEMS = %w[de_grv de_bav de_riester us_ss uk_state uk_workplace custom].freeze
  TAX_TREATMENTS = %w[
    de_renten de_bav de_riester de_private
    uk_state uk_dc_drawdown uk_dc_25pct uk_isa
    custom_post_tax
  ].freeze
  PAYOUT_SHAPES = %w[monthly_for_life monthly_fixed_term lump_sum lump_plus_annuity].freeze

  belongs_to :goal_retirement, class_name: "Goal::Retirement", foreign_key: :goal_retirement_id
  has_many :statements, class_name: "Goal::RetirementStatement", dependent: :destroy

  validates :name, presence: true, length: { maximum: 255 }
  validates :kind, inclusion: { in: KINDS }
  validates :country, inclusion: { in: COUNTRIES }
  validates :pension_system, inclusion: { in: PENSION_SYSTEMS }
  validates :tax_treatment, inclusion: { in: TAX_TREATMENTS }
  validates :payout_shape, inclusion: { in: PAYOUT_SHAPES }
  validates :start_age, presence: true,
    numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 120 }
  validates :end_age,
    numericality: { only_integer: true, greater_than: :start_age, less_than_or_equal_to: 120 },
    allow_nil: true
  validates :amount, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :currency, presence: true
  validates :effective_rate_override,
    numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }, allow_nil: true
  validate :end_age_required_for_fixed_term

  monetize :amount

  def latest_statement
    statements.order(:received_on).last
  end

  private
    def end_age_required_for_fixed_term
      return unless payout_shape == "monthly_fixed_term"
      errors.add(:end_age, :required_for_fixed_term) if end_age.blank?
    end
end
