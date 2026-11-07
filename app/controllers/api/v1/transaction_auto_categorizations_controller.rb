# frozen_string_literal: true

# Queues AI auto-categorization for transactions through the same
# AutoCategorizeJob the "Auto-categorize transactions with AI" rule action
# uses, so the family's categorization provider, confidence threshold and
# locked (user-set) categories apply exactly as they do there.
class Api::V1::TransactionAutoCategorizationsController < Api::V1::BaseController
  # Bounds one request: the transaction_ids list, or how many eligible
  # transactions one request without a list queues.
  MAX_TRANSACTION_IDS = 1_000

  before_action :ensure_write_scope
  before_action :ensure_categorization_provider
  before_action :ensure_family_has_categories

  # POST /api/v1/transactions/auto_categorize
  def create
    requested_ids = requested_transaction_ids
    return if performed?

    after_id = after_transaction_id(requested_ids)
    return if performed?

    family = current_resource_owner.family
    scope = family.auto_categorizable_transactions_for(current_resource_owner)
    scope = scope.where(id: requested_ids) if requested_ids

    # Without a list, queue at most MAX_TRANSACTION_IDS eligible transactions
    # per request, in id order. A transaction the provider finds no confident
    # match for stays eligible, so the client pages on with
    # after_transaction_id rather than re-sending the same first page.
    truncated = false
    next_after_id = nil
    unless requested_ids
      scope = scope.where(Transaction.arel_table[:id].gt(after_id)) if after_id
      ids = scope.order(:id).limit(MAX_TRANSACTION_IDS + 1).pluck(:id)
      truncated = ids.size > MAX_TRANSACTION_IDS
      ids = ids.first(MAX_TRANSACTION_IDS)
      next_after_id = ids.last if truncated
      scope = scope.where(id: ids)
    end

    queued_ids, unqueued_ids = family.queue_auto_categorization(scope, user: current_resource_owner)

    if unqueued_ids.any?
      return render json: {
        error: "service_unavailable",
        message: "Could not queue #{unqueued_ids.size} of #{queued_ids.size + unqueued_ids.size} transactions; " \
                 "#{queued_ids.size} were queued. Retry with unqueued_transaction_ids as transaction_ids to queue the rest.",
        queued_count: queued_ids.size,
        transaction_ids: queued_ids,
        unqueued_transaction_ids: unqueued_ids,
        skipped_transaction_ids: skipped_ids(requested_ids, queued_ids + unqueued_ids),
        truncated: truncated,
        next_after_transaction_id: next_after_id
      }, status: :service_unavailable
    end

    render json: {
      queued_count: queued_ids.size,
      transaction_ids: queued_ids,
      # Requested ids that were not queued: already categorized, locked, a
      # transfer or split parent, or not a transaction this key can annotate.
      # One list for every reason, so it says nothing about another
      # family's ids.
      skipped_transaction_ids: skipped_ids(requested_ids, queued_ids),
      # True when more than MAX_TRANSACTION_IDS transactions were eligible and
      # no list was sent: only the first MAX_TRANSACTION_IDS were queued.
      truncated: truncated,
      # Send as after_transaction_id to queue the next page; nil when
      # nothing is left.
      next_after_transaction_id: next_after_id
    }, status: :accepted
  end

  private

    def skipped_ids(requested_ids, handled_ids)
      requested_ids ? requested_ids - handled_ids : []
    end

    def ensure_write_scope
      authorize_scope!(:write)
    end

    def ensure_categorization_provider
      return if current_resource_owner.family.resolved_categorization_provider.present?

      render_validation_error("No categorization provider is configured")
    end

    # The categorizer picks from the family's own categories and fails every
    # job when there are none. These API jobs have no rule run to record that
    # failure, so reject up front instead of queuing work that can't succeed.
    def ensure_family_has_categories
      return if current_resource_owner.family.categories.exists?

      render_validation_error("The family has no categories to assign; create categories first")
    end

    # nil when the caller sent no list (every eligible transaction), otherwise
    # the unique ids it named, lowercased so they compare equal to the ids
    # PostgreSQL returns.
    def requested_transaction_ids
      return nil unless params.key?(:transaction_ids)

      raw = params[:transaction_ids]
      unless raw.is_a?(Array) && raw.any?
        render_validation_error("transaction_ids must be a non-empty array of transaction IDs")
        return nil
      end

      # The limit applies to the list as sent, duplicates included. Checked
      # before the per-element format pass so an oversized payload fails fast.
      if raw.size > MAX_TRANSACTION_IDS
        render_validation_error("transaction_ids accepts at most #{MAX_TRANSACTION_IDS} IDs")
        return nil
      end

      unless raw.all? { |id| id.is_a?(String) && valid_uuid?(id) }
        render_validation_error("transaction_ids must be a non-empty array of transaction IDs")
        return nil
      end

      raw.map(&:downcase).uniq
    end

    # Cursor for requests without a list: only transactions with a greater id
    # are considered. nil when not sent.
    def after_transaction_id(requested_ids)
      return nil unless params.key?(:after_transaction_id)

      raw = params[:after_transaction_id]
      if requested_ids
        render_validation_error("after_transaction_id cannot be combined with transaction_ids")
        return nil
      end

      unless raw.is_a?(String) && valid_uuid?(raw)
        render_validation_error("after_transaction_id must be a transaction ID")
        return nil
      end

      raw.downcase
    end
end
