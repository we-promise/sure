# frozen_string_literal: true

# Queues AI auto-categorization for transactions.
#
# The web app only reaches the categorizer through a rule with the
# "Auto-categorize transactions with AI" action, so an API client that imports
# or syncs transactions had no way to ask for categories without creating and
# running a rule. This queues the same AutoCategorizeJob the rule action does,
# so the family's categorization provider, confidence threshold and locked
# (user-set) categories are honored exactly as they are there.
class Api::V1::TransactionAutoCategorizationsController < Api::V1::BaseController
  # Bounds one request's id list; omit transaction_ids to cover every
  # eligible transaction instead.
  MAX_TRANSACTION_IDS = 1_000

  before_action :ensure_write_scope
  before_action :ensure_categorization_provider
  before_action :ensure_family_has_categories

  # POST /api/v1/transactions/auto_categorize
  def create
    requested_ids = requested_transaction_ids
    return if performed?

    family = current_resource_owner.family
    scope = family.auto_categorizable_transactions_for(current_resource_owner)
    scope = scope.where(id: requested_ids) if requested_ids

    queued_ids, unqueued_ids = family.queue_auto_categorization(scope)

    if unqueued_ids.any?
      return render json: {
        error: "service_unavailable",
        message: "Could not queue #{unqueued_ids.size} of #{queued_ids.size + unqueued_ids.size} transactions; " \
                 "#{queued_ids.size} were queued. Retry to queue the rest.",
        queued_count: queued_ids.size,
        transaction_ids: queued_ids,
        unqueued_transaction_ids: unqueued_ids
      }, status: :service_unavailable
    end

    render json: {
      queued_count: queued_ids.size,
      transaction_ids: queued_ids,
      # Requested ids that were not queued: already categorized, locked, a
      # transfer or split parent, or not a transaction this key can annotate.
      # One list for every reason, so it says nothing about another
      # family's ids.
      skipped_transaction_ids: requested_ids ? requested_ids - queued_ids : []
    }, status: :accepted
  end

  private

    def ensure_write_scope
      authorize_scope!(:write)
    end

    def ensure_categorization_provider
      return if performed?
      return if current_resource_owner.family.resolved_categorization_provider.present?

      render_validation_error("No categorization provider is configured")
    end

    # The categorizer picks from the family's own categories and fails every
    # job when there are none. These API jobs have no rule run to record that
    # failure, so reject up front instead of queuing work that can't succeed.
    def ensure_family_has_categories
      return if performed?
      return if current_resource_owner.family.categories.exists?

      render_validation_error("The family has no categories to assign; create categories first")
    end

    # nil when the caller sent no list (every eligible transaction), otherwise
    # the unique ids it named, lowercased so they compare equal to the ids
    # PostgreSQL returns.
    def requested_transaction_ids
      return nil unless params.key?(:transaction_ids)

      raw = params[:transaction_ids]
      unless raw.is_a?(Array) && raw.any? && raw.all? { |id| id.is_a?(String) && valid_uuid?(id) }
        render_validation_error("transaction_ids must be a non-empty array of transaction IDs")
        return nil
      end

      # The limit applies to the list as sent, duplicates included.
      if raw.size > MAX_TRANSACTION_IDS
        render_validation_error("transaction_ids accepts at most #{MAX_TRANSACTION_IDS} IDs")
        return nil
      end

      raw.map(&:downcase).uniq
    end
end
