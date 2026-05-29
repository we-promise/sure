class Goal::Retirement < Goal
  ADJUSTMENTS_LIMIT = 10

  belongs_to :owner, class_name: "User", foreign_key: :user_id

  has_many :pension_sources, foreign_key: :goal_retirement_id, dependent: :destroy
  has_many :statements, class_name: "Goal::RetirementStatement",
    foreign_key: :goal_retirement_id, dependent: :destroy
  has_many :adjustments, class_name: "Goal::RetirementAdjustment",
    foreign_key: :goal_retirement_id, dependent: :destroy
  has_many :retirement_bucket_entries, foreign_key: :goal_retirement_id, dependent: :destroy
  has_many :bucket_accounts, through: :retirement_bucket_entries, source: :account

  validates :owner, presence: true
  validate :owner_belongs_to_family
  validate :adjustments_within_limit

  def editable_by?(user)
    return false if user.nil?
    user_id == user.id
  end

  private
    # Retirement uses RetirementBucketEntry for asset selection, not the
    # goal_accounts depository join, so the parent validations (which run
    # against goal_accounts) would always fail. No-op them on the subtype.
    def must_have_at_least_one_linked_account
    end

    def linked_accounts_must_be_depository
    end

    def owner_belongs_to_family
      return if owner.nil? || family_id.nil?
      errors.add(:owner, :must_belong_to_family) unless owner.family_id == family_id
    end

    def adjustments_within_limit
      return if adjustments.reject(&:marked_for_destruction?).size <= ADJUSTMENTS_LIMIT
      errors.add(:adjustments, :too_many, count: ADJUSTMENTS_LIMIT)
    end
end
