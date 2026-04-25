# frozen_string_literal: true

# Controller for bulk updating multiple transactions at once
class Transactions::BulkUpdatesController < ApplicationController
  # Renders the bulk update form
  def new
  end

  # Performs the bulk update on selected transactions
  def create
    # Skip split parents from bulk update - update children instead
    updated = Current.family
                     .entries
                     .excluding_split_parents
                     .where(id: bulk_update_params[:entry_ids])
                     .bulk_update!(bulk_update_params, update_tags: tags_provided?)

    redirect_back_or_to transactions_path, notice: "#{updated} transactions updated"
  end

  private

    # Returns the permitted params for bulk updating transactions
    def bulk_update_params
      params.require(:bulk_update)
            .permit(:date, :notes, :name, :category_id, :merchant_id, entry_ids: [], tag_ids: [])
    end

    # Check if tag_ids was explicitly provided in the request.
    # This distinguishes between "user wants to update tags" vs "user didn't touch tags field".
    def tags_provided?
      bulk_update = params[:bulk_update]
      bulk_update.respond_to?(:key?) && bulk_update.key?(:tag_ids)
    end
end
