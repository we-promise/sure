# What the assistant thinks a security is, held separately from what it IS.
#
# The separation is the point. `classification_source` exists so a figure in an
# allocation chart can be traced to whoever asserted it, and a model that wrote
# straight to `securities` would be indistinguishable from a provider. So the
# assistant writes here, a person approves, and only approval touches the
# security.
#
# Family-scoped, because the proposal belongs to the household whose assistant
# made it. Its EFFECT is not: approving writes the globally shared `securities`
# row, as every other classification writer does.
class Security::ClassificationProposal < ApplicationRecord
  STATUSES = %w[pending approved rejected].freeze

  belongs_to :security
  belongs_to :family

  validates :status, inclusion: { in: STATUSES }
  # The same vocabularies `Security` validates, and for a concrete reason: they
  # are database check constraints on `securities`, so storing a proposal that
  # could not be approved would only defer the failure to approval time.
  validates :asset_class, inclusion: { in: Security::ASSET_CLASSES }, allow_nil: true
  validates :asset_sub_class, inclusion: { in: Security::ASSET_SUB_CLASSES }, allow_nil: true
  validates :region, inclusion: { in: Security::REGION_KEYS }, allow_nil: true
  # On every save that leaves the proposal pending, not on create only:
  # `propose!` revives an existing row through `update!`, and that path must
  # meet the same veto. An approval or a rejection is not a new proposal, so
  # it is not checked: a hand classification must not stop the person
  # clearing the proposal out of the queue.
  validate :security_is_open_to_a_proposal, if: :pending?
  validate :answers_something
  validate :sub_class_has_a_class

  scope :pending, -> { where(status: "pending") }

  STATUSES.each do |state|
    define_method("#{state}?") { status == state }
  end

  ANSWER_COLUMNS = %i[asset_class asset_sub_class sector region rationale].freeze

  # Replaces any existing proposal for this pair rather than accumulating, so a
  # review screen can never show one security twice with two different answers.
  # The unique index on (family_id, security_id) is what makes that a guarantee
  # rather than a convention.
  #
  # Replaces, not merges: every answer column the new proposal leaves out is
  # cleared, or a region-only proposal would revive someone else's asset class
  # and approve it as "ai".
  #
  # Two first proposals for one pair can both miss `find_by`; the loser's
  # INSERT hits the unique index, and it replaces the winner's row instead.
  def self.propose!(security:, family:, **attrs)
    answer = ANSWER_COLUMNS.index_with(nil).merge(attrs)
    attempts = 0

    begin
      existing = find_by(security: security, family: family)
      return existing.tap { |p| p.update!(status: "pending", **answer) } if existing

      # A savepoint, so the unique violation does not poison a caller's
      # transaction before the retry reads the winner's row.
      transaction(requires_new: true) { create!(security: security, family: family, **answer) }
    rescue ActiveRecord::RecordNotUnique
      attempts += 1
      retry if attempts == 1
      raise
    end
  end

  # Returns false rather than raising when the security has been answered since
  # the proposal was made -- that window is exactly where a user can pick up the
  # drawer and classify it by hand, and their answer wins.
  def approve!
    # `pending?` is checked inside THIS row's lock, not against whatever the
    # in-memory object last read. Checked outside, two requests on one proposal
    # both pass it, and an approve racing a reject leaves the security
    # classified "ai" behind a row that says "rejected" -- the state #reject!'s
    # own comment says it exists to prevent.
    #
    # The veto is then re-checked inside the SECURITY's lock for the same
    # reason: a concurrent manual save committing between check and write would
    # otherwise be overwritten silently, which is the case the veto exists for.
    #
    # Lock order is proposal then security, and nothing takes them the other way
    # round.
    approved = false

    with_lock do
      next unless pending?

      # `with_lock` reloads the row under FOR UPDATE, so the veto reads what
      # is committed now.
      security.with_lock do
        next if security.classification_locked? || security.classification_source == "manual"

        security.update!(proposed_attributes.merge(source_attributes))
        update!(status: "approved")
        approved = true
      end
    end

    approved
  end

  # Conditional for the same reason `approve!` is: a stale form from another tab
  # would otherwise move an already-approved proposal to `rejected` while the
  # security stays classified `"ai"`, leaving a row that denies a classification
  # still in force.
  def reject!
    rejected = false

    with_lock do
      next unless pending?

      update!(status: "rejected")
      rejected = true
    end

    rejected
  end

  private
    # Only the columns this proposal actually answered. A proposal that could
    # only name the region must not blank out an asset class the security
    # already holds.
    #
    # `asset_class` and `asset_sub_class` are the exception, and they move
    # TOGETHER. `compact_blank` drops a blank sub-class while keeping the class
    # beside it, so re-classifying a security from equity/stock to
    # fixed_income with no sub-class left `stock` sitting under `fixed_income`
    # -- a pair the model cannot reject, because it validates the two columns
    # independently. Answering the class therefore writes the sub-class too,
    # blank included, so the pair is always the proposal's own answer rather
    # than half of it over half of someone else's.
    def proposed_attributes
      attrs = { sector: sector, region: region }.compact_blank
      return attrs if asset_class.blank?

      attrs.merge(asset_class: asset_class, asset_sub_class: asset_sub_class.presence)
    end

    # `classification_source` says who set the ASSET classification, and in
    # the precedence order `Security` documents (default -> provider -> ai ->
    # manual) a provider may replace only `nil` or `"default"`. So stamping
    # `"ai"` for a proposal that answered only a sector or a region would shut
    # a provider out of the asset columns FOR GOOD, leaving the security
    # permanently half-classified -- a lock-out bought with a region.
    #
    # This is `answers_something`'s reasoning applied one step further in.
    # That guard refuses a proposal answering nothing; this one declines to
    # claim the classification for a proposal that answered something else.
    def source_attributes
      return { classification_locked: false } if asset_class.blank?

      { classification_source: "ai", classification_locked: false }
    end

    # A proposal with nothing in it would be storable AND approvable, and
    # approval would stamp `classification_source: "ai"` on a security with no
    # classification at all. Since a provider may replace only `nil` or
    # `"default"`, that security could then never be classified by a provider
    # again -- a permanent lock-out bought with no information.
    def answers_something
      return if [ asset_class, asset_sub_class, sector, region ].any?(&:present?)

      errors.add(:base, "must propose at least one classification")
    end

    # `proposed_attributes` writes a sub-class only beside a class, so a
    # sub-class alone would be approved, marked approved, and write nothing.
    def sub_class_has_a_class
      return if asset_sub_class.blank? || asset_class.present?

      errors.add(:asset_sub_class, "needs an asset class beside it")
    end

    def security_is_open_to_a_proposal
      return if security.blank?

      if security.classification_locked?
        errors.add(:security, "has a locked classification")
      elsif security.classification_source == "manual"
        errors.add(:security, "has already been classified by hand")
      end
    end
end
