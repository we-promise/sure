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

  # Blank is "not answered" everywhere below, so it is stored as nil rather
  # than refused by the vocabulary checks.
  normalizes :asset_class, :asset_sub_class, :region, :sector, :rationale, with: ->(value) { value.presence }

  validates :status, inclusion: { in: STATUSES }
  # The same vocabularies `Security` validates, and for a concrete reason: they
  # are database check constraints on `securities`, so storing a proposal that
  # could not be approved would only defer the failure to approval time.
  validates :asset_class, inclusion: { in: Security::ASSET_CLASSES }, allow_nil: true
  validates :asset_sub_class, inclusion: { in: Security::ASSET_SUB_CLASSES }, allow_nil: true
  validates :region, inclusion: { in: Security::REGION_KEYS }, allow_nil: true
  # Free text from the model or an `/mcp` client, read by a person on a review
  # screen. Bounded so one entry cannot store megabytes in front of them.
  validates :sector, length: { maximum: 255 }
  validates :rationale, length: { maximum: 2000 }
  # Postgres refuses a NUL in a text column, so it is an invalid answer here
  # rather than an error at the INSERT.
  validate :text_has_no_nul
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

  # Replaces a pending proposal for this pair rather than accumulating, so a
  # review screen can never show one security twice with two different answers.
  # A proposal a person has already approved or rejected is left as it is and
  # returned unchanged: re-proposing must not reopen a rejection, nor erase the
  # record of an approval. Callers check `pending?` on the result.
  # The unique index on (family_id, security_id) is what makes that a guarantee
  # rather than a convention.
  #
  # Replaces, not merges: every answer column the new proposal leaves out is
  # cleared, or a region-only proposal would revive someone else's asset class
  # and approve it as "ai".
  #
  # Two first proposals for one pair can both miss `find_by`; the loser's
  # INSERT hits the unique index, and it replaces the winner's row instead.
  #
  # The row is replaced under its lock, which reloads it: `update!` writes
  # only changed columns, so a copy read before another proposal added a
  # sector would see nil over nil and leave that sector in place.
  def self.propose!(security:, family:, **attrs)
    attrs.assert_valid_keys(*ANSWER_COLUMNS)
    answer = ANSWER_COLUMNS.index_with(nil).merge(attrs)
    attempts = 0

    begin
      existing = find_by(security: security, family: family)
      if existing
        existing.with_lock { existing.update!(answer) if existing.pending? }
        return existing
      end

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
  # the proposal was made -- by hand, or by a provider classifying it after the
  # proposal was last written -- or when the security cannot store the answer.
  # That window is exactly where a user can pick up the drawer and classify it
  # by hand, and their answer wins.
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
        next if answered_by_provider_since_proposed?

        security.update!(proposed_attributes.merge(source_attributes))
        update!(status: "approved")
        approved = true
      rescue ActiveRecord::RecordInvalid => e
        # A field the proposal does not touch can make the shared row invalid
        # (a provider no longer registered). `update!` wrote nothing, so the
        # approval is refused, the proposal stays pending, and support has a
        # trail.
        log_refused_approval(e)
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
    #
    # Answering only the class it already has keeps the security's sub-class:
    # an equity ETF re-proposed as "equity" stays an ETF rather than losing the
    # sub-class that keeps its listing country out of its region.
    #
    # A fund approved without a region loses the region its listing implies,
    # as a provider's classification of a fund does: a listing or domicile
    # country says nothing about what the fund holds. A region set any other
    # way stays.
    def proposed_attributes
      attrs = { sector: sector, region: region }.compact_blank
      if asset_class.present?
        keep_sub_class = asset_sub_class.blank? && asset_class == security.asset_class
        attrs[:asset_class] = asset_class
        attrs[:asset_sub_class] = asset_sub_class.presence unless keep_sub_class
      end

      sub_class = attrs.key?(:asset_sub_class) ? attrs[:asset_sub_class] : security.asset_sub_class
      if region.blank? && sub_class.in?(%w[etf mutual_fund]) &&
          security.region.present? && security.region == Security::REGIONS.dig(security.country_code.to_s.upcase, "region")
        attrs[:region] = nil
      end

      attrs
    end

    # A provider stamp newer than the proposal means the security was
    # classified after the assistant last proposed for it, and the stale
    # proposal must not replace that answer.
    def answered_by_provider_since_proposed?
      security.classification_source == "provider" &&
        security.classification_fetched_at.present? && security.classification_fetched_at > updated_at
    end

    def log_refused_approval(error)
      DebugLogEntry.capture(
        category: "security_classification",
        level: "warn",
        message: "Classification proposal could not be approved",
        source: self.class.name,
        family: family,
        metadata: { proposal_id: id, security_id: security_id, errors: error.record.errors.full_messages }
      )
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
      return {} if asset_class.blank?

      { classification_source: "ai" }
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

    def text_has_no_nul
      %i[sector rationale].each do |column|
        errors.add(column, "must not contain a NUL character") if public_send(column)&.include?("\0")
      end
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
