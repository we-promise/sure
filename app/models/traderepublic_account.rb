class TraderepublicAccount < ApplicationRecord
  # Stocke le snapshot brut du compte (portfolio)
  def upsert_traderepublic_snapshot!(account_snapshot)
    self.raw_payload = account_snapshot
    save!
  end
  belongs_to :traderepublic_item
  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :linked_account, through: :account_provider, source: :account

  # Stocke le snapshot brut des transactions (timeline enrichie)
  def upsert_traderepublic_transactions_snapshot!(transactions_snapshot)
    Rails.logger.info "TraderepublicAccount #{id}: upsert_traderepublic_transactions_snapshot! - snapshot keys=#{transactions_snapshot.is_a?(Hash) ? transactions_snapshot.keys : transactions_snapshot.class}"
    Rails.logger.info "TraderepublicAccount \\#{id}: upsert_traderepublic_transactions_snapshot! - snapshot preview=\\#{transactions_snapshot.inspect[0..300]}"

    # If the new snapshot is nil or empty, do not overwrite existing payload
    if transactions_snapshot.nil? || (transactions_snapshot.respond_to?(:empty?) && transactions_snapshot.empty?)
      Rails.logger.info "TraderepublicAccount #{id}: Received empty transactions snapshot, skipping overwrite."
      return
    end

    # If this is the first import or there is no existing payload, just set it
    if self.raw_transactions_payload.nil? || (self.raw_transactions_payload.respond_to?(:empty?) && self.raw_transactions_payload.empty?)
      self.raw_transactions_payload = transactions_snapshot
      save!
      return
    end

    # Merge/append new transactions to existing payload (assuming array of items under 'items' key)
    existing = self.raw_transactions_payload
    new_data = transactions_snapshot

    # Support both Hash and Array structures (prefer Hash with 'items')
    existing_items = if existing.is_a?(Hash) && existing["items"].is_a?(Array)
      existing["items"]
    elsif existing.is_a?(Array)
      existing
    else
      []
    end

    new_items = if new_data.is_a?(Hash) && new_data["items"].is_a?(Array)
      new_data["items"]
    elsif new_data.is_a?(Array)
      new_data
    else
      []
    end

    # Only append items that are not already present (by id if available)
    existing_ids = existing_items.map { |i| i["id"] }.compact
    items_to_add = new_items.reject { |i| i["id"] && existing_ids.include?(i["id"]) }

    merged_items = existing_items + items_to_add

    # Rebuild the payload in the same structure as before
    merged_payload = if existing.is_a?(Hash)
      existing.merge("items" => merged_items)
    else
      merged_items
    end

    self.raw_transactions_payload = merged_payload
    save!
  end

  # Pour compatibilité avec l'importer
  def last_transaction_date
    return nil unless linked_account && linked_account.transactions.any?
    linked_account.transactions.order(date: :desc).limit(1).pick(:date)
  end
end
