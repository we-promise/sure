class Transactions::BulkUpdatesController < ApplicationController
  def new
  end

  def create
    # Reject an out-of-range reconciled_status before it ever reaches
    # bulk_update! — the enum's `validate: true` means an invalid value
    # would otherwise raise ActiveRecord::RecordInvalid partway through the
    # bulk transaction. The single-row TransactionsController#reconcile
    # action can't hit this (advance_reconciled_status! only ever assigns a
    # value from RECONCILED_STATUS_CYCLE), but this form field takes
    # arbitrary user input, so it needs the same graceful-failure handling.
    reconciled_status = bulk_update_params[:reconciled_status]
    if reconciled_status.present? && !Entry.reconciled_statuses.key?(reconciled_status)
      redirect_back_or_to transactions_path, alert: t("transactions.reconcile.failure")
      return
    end

    # Skip split parents from bulk update - update children instead
    scoped_params = family_scoped_bulk_update_params
    selected = Current.annotatable_entries
                      .excluding_split_parents
                      .where(id: bulk_update_params[:entry_ids])

    # Owners and full_control shares may change every field; read_write shares
    # may only annotate (notes, category, merchant, tags), as on a single entry.
    # Read-only and unshared accounts are left out entirely.
    rows = selected.pluck(:id, Account.writable_by_sql(Current.user))
    full_ids = rows.select(&:last).map(&:first).uniq
    annotate_ids = rows.map(&:first).uniq - full_ids

    updated = Entry.transaction do
      bulk_update_entries(full_ids, scoped_params) +
        bulk_update_entries(annotate_ids, scoped_params.slice(*AccountShare::ANNOTATE_ENTRY_ATTRIBUTES, *AccountShare::ANNOTATE_TRANSACTION_ATTRIBUTES))
    end

    redirect_back_or_to transactions_path, notice: "#{updated} transactions updated"
  rescue ActiveRecord::RecordInvalid => e
    Rails.logger.error("Bulk update failed: #{e.message}")
    redirect_back_or_to transactions_path, alert: t("transactions.reconcile.failure")
  end

  private
    def bulk_update_entries(entry_ids, attributes)
      return 0 if entry_ids.empty?

      Current.family.entries.where(id: entry_ids).includes(:entryable)
             .bulk_update!(attributes, update_tags: attributes.key?(:tag_ids))
    end

    def bulk_update_params
      params.require(:bulk_update)
            .permit(:date, :notes, :name, :category_id, :merchant_id, :reconciled_status, entry_ids: [], tag_ids: [])
    end

    # Resolve category, merchant and tag IDs through the current family so IDs
    # belonging to another family are dropped instead of being attached.
    def family_scoped_bulk_update_params
      scoped = bulk_update_params.to_h.symbolize_keys

      if scoped[:category_id].present?
        scoped[:category_id] = Current.family.categories.where(id: scoped[:category_id]).pick(:id)
      end

      if scoped[:merchant_id].present?
        scoped[:merchant_id] = Current.family.available_merchants_for(Current.user).where(id: scoped[:merchant_id]).pick(:id)
      end

      if scoped.key?(:tag_ids)
        tag_ids = Array.wrap(scoped[:tag_ids]).reject(&:blank?)
        resolved = tag_ids.any? ? Current.family.tags.where(id: tag_ids).pluck(:id) : []

        # Tags were requested but none belong to this family: leave the entries'
        # tags alone instead of wiping them. An explicit empty list still clears.
        if tag_ids.any? && resolved.empty?
          scoped.delete(:tag_ids)
        else
          scoped[:tag_ids] = resolved
        end
      end

      scoped
    end
end
