class BudgetPlan < ApplicationRecord
  # A month-shaped slug ("jan-2025") would collide with the bare month params
  # that address the default plan's budgets (see Budget.resolve_param).
  MONTH_SLUG_FORMAT = /\A[a-z]{3}-\d{4}\z/

  belongs_to :family

  has_many :budgets, dependent: :destroy
  has_many :budget_plan_accounts, dependent: :destroy
  has_many :accounts, through: :budget_plan_accounts

  validates :name, presence: true, length: { maximum: 255 }
  validates :slug, presence: true, uniqueness: { scope: :family_id }
  validate :accounts_must_belong_to_family

  before_validation :generate_slug, if: -> { slug.blank? || will_save_change_to_name? }
  before_destroy :prevent_destroying_default

  scope :default_first, -> { order(is_default: :desc).order(Arel.sql("LOWER(budget_plans.name) ASC")) }

  # A plan with no linked accounts covers all of the family's accounts.
  def scoped?
    budget_plan_accounts.any?
  end

  def scoped_account_ids
    scoped? ? account_ids : nil
  end

  # Account-name payload shared by the assistant budget tools. "all_accounts"
  # means the plan tracks every account in the family; pass user: to hide
  # accounts that aren't shared with that member.
  def scoped_account_names(user: nil)
    return "all_accounts" unless scoped?

    (user ? accounts.accessible_by(user) : accounts).map(&:name).sort
  end

  # generate_slug checks existing slugs before the INSERT, so two concurrent
  # saves of the same name can both pass the check and collide on the unique
  # index. Rescue the race like Family#default_budget_plan: the winner's row
  # is visible by then, so one regeneration picks the next free suffix.
  def save(**options, &block)
    with_slug_collision_retry { super(**options, &block) }
  end

  def save!(**options, &block)
    with_slug_collision_retry { super(**options, &block) }
  end

  private
    def with_slug_collision_retry
      retried = false
      begin
        yield
      rescue ActiveRecord::RecordNotUnique => e
        raise if retried || !e.message.include?("index_budget_plans_on_family_id_and_slug")

        retried = true
        generate_slug
        retry
      end
    end

    def generate_slug
      base = name.to_s.parameterize
      base = "plan" if base.blank?
      base = "#{base}-plan" if base.match?(MONTH_SLUG_FORMAT)

      candidate = base
      sequence = 2
      while family.budget_plans.where.not(id: id).exists?(slug: candidate)
        candidate = "#{base}-#{sequence}"
        sequence += 1
      end

      self.slug = candidate
    end

    def accounts_must_belong_to_family
      return if family.nil?

      foreign = budget_plan_accounts.reject(&:marked_for_destruction?).reject do |bpa|
        bpa.account.nil? || bpa.account.family_id == family_id
      end
      return if foreign.empty?

      errors.add(:accounts, :must_belong_to_family)
    end

    def prevent_destroying_default
      return unless is_default?

      errors.add(:base, :cannot_destroy_default)
      throw :abort
    end
end
