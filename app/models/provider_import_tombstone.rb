class ProviderImportTombstone < ApplicationRecord
  belongs_to :account

  validates :source, :external_id, presence: true
  validates :external_id, uniqueness: { scope: [ :account_id, :source ] }

  # Extra keys on a transaction that hold external_ids the row used to answer
  # to. All three feed the batch processors' excluded_ids, so a deleted
  # survivor's retired identities must be tombstoned alongside its own id.
  ALIAS_EXTRA_KEYS = %w[superseded_external_ids auto_claimed_pending_ids].freeze

  # Records a tombstone for the entry's own external_id plus every retired
  # identity stored on its transaction, so a later sync does not resurrect
  # any of them from a stored payload. Idempotent: re-recording the same
  # identity is a no-op.
  #
  # @param entry [Entry] a provider-sourced entry being destroyed
  # @return [void]
  def self.record_for_entry!(entry)
    return if entry.external_id.blank? || entry.source.blank?

    ([ entry.external_id ] + alias_external_ids_for(entry)).uniq.each do |external_id|
      begin
        find_or_create_by!(account_id: entry.account_id, source: entry.source, external_id: external_id)
      rescue ActiveRecord::RecordNotUnique
        # Another destroy recorded the same identity first; the tombstone exists.
        nil
      end
    end
  end

  # External ids currently tombstoned for an account, as a Set, for a batch
  # processor to exclude in one lookup per row. Scoped by source when given,
  # so one provider's tombstones never suppress another provider's rows.
  #
  # @param account [Account] the account being synced
  # @param source [String, nil] provider source key (e.g. "enable_banking")
  # @return [Set<String>]
  def self.external_ids_for(account, source: nil)
    return Set.new if account.blank?

    scope = where(account_id: account.id)
    scope = scope.where(source: source) if source.present?
    scope.pluck(:external_id).to_set
  end

  # True when this (account, source, external_id) was deleted and must not
  # be re-imported.
  def self.tombstoned?(account:, source:, external_id:)
    return false if account.blank? || source.blank? || external_id.blank?

    exists?(account_id: account.id, source: source, external_id: external_id)
  end

  # Clears every tombstone for one provider link, for unlinking an account or
  # removing the provider: a fresh link must import the provider's history
  # from scratch instead of inheriting the old link's deletions.
  #
  # @param account [Account] the unlinked account
  # @param source [String] provider source key (e.g. "enable_banking")
  # @return [Integer] number of tombstones cleared
  def self.clear_for_account!(account:, source:)
    return 0 if account.blank? || source.blank?

    where(account_id: account.id, source: source).delete_all
  end

  class << self
    private

      # Every retired identity a transaction carries: the ids it superseded
      # when an identifier arrived late, the pending ids it auto-claimed, and
      # the pending ids merged into it by hand. The manual_merge branch is
      # an Array in current format and a legacy Hash otherwise.
      #
      # @param entry [Entry] the entry being destroyed
      # @return [Array<String>]
      def alias_external_ids_for(entry)
        return [] unless entry.entryable_type == "Transaction"

        extra = entry.transaction&.extra || {}
        ids = []
        ALIAS_EXTRA_KEYS.each { |key| ids.concat(Array(extra[key])) }

        merges = extra["manual_merge"]
        merges = [ merges ] if merges.is_a?(Hash)
        Array(merges).each do |merge|
          ids << merge["merged_from_external_id"] if merge.is_a?(Hash)
        end

        ids.compact
      end
  end
end
