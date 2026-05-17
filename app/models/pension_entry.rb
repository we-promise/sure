class PensionEntry < ApplicationRecord
  belongs_to :retirement_config

  validates :recorded_at, presence: true, uniqueness: { scope: :retirement_config_id }
  validates :current_points, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :current_monthly_pension, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :projected_monthly_pension, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true

  scope :chronological, -> { order(recorded_at: :asc) }
  scope :reverse_chronological, -> { order(recorded_at: :desc) }

  # Calculate the points gained since the previous entry.
  # For bulk rendering, prefer RetirementConfig#pension_entries_with_gains
  # to avoid N+1 queries.
  def points_gained
    previous = retirement_config.pension_entries
      .where("recorded_at < ?", recorded_at)
      .order(recorded_at: :desc)
      .first

    return current_points unless previous
    current_points - previous.current_points
  end
end
