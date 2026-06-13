class Goal::Retirement < Goal
  belongs_to :owner, class_name: "User", foreign_key: :user_id

  validates :owner, presence: true
  validate :owner_belongs_to_family

  def editable_by?(user)
    return false if user.nil?
    user_id == user.id
  end

  private
    # Retirement uses RetirementBucketEntry (PR2) for asset selection, not
    # the goal_accounts depository join. The parent validations operate on
    # goal_accounts, so they would always fail for retirement subtypes.
    def must_have_at_least_one_linked_account
    end

    def linked_accounts_must_be_depository
    end

    def owner_belongs_to_family
      return if owner.nil? || family_id.nil?
      errors.add(:owner, :must_belong_to_family) unless owner.family_id == family_id
    end
end
