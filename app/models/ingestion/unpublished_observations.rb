# Retained connection changes need stable source identities even before account
# setup. These observations cannot create evidence links or modify a financial
# target. Previously bound observations wait for explicit replay/reconciliation.
class Ingestion::UnpublishedObservations
  def initialize(external_account:, batch:)
    @external_account, @batch = external_account, batch
  end

  def apply(page)
    generation = batch.provider_sync_generation
    binding = generation&.context_snapshot&.dig("accounts", external_account.external_id)
    unless generation&.sealed? && generation.stream == batch.stream && %w[transactions activities].include?(batch.stream) && batch.generation_role == "account" &&
        batch.external_account_id == external_account.id && batch.family_id == external_account.family_id &&
        batch.provider_connection_id == external_account.provider_connection_id && binding&.fetch("publication", nil) == "retained" &&
        batch.source_policy_version.nil? && page.complete? && page.mode == "delta" &&
        page.coverage["pending_absence_authoritative"] == false && valid_removal_policy?(page)
      raise Provider::AccountData::InvalidResponse, "Unpublished observations require a sealed retained account change set"
    end
    unless page.records.all? { |record| record.kind == record_kind } &&
        (page.records.map { |record| record[:external_id] } & page.removed_ids).empty?
      raise Provider::AccountData::InvalidResponse, "Retained changes have conflicting identities or resource kinds"
    end
    page.records.each { |record| observe(record) }
    page.removed_ids.each do |id|
      observation = source_record(id)
      next if observation.account_id.present?
      observation.assign_attributes(ingestion_batch: batch, pending: false, withdrawn: true)
      observation.save!
    end
  end

  private
    attr_reader :external_account, :batch

    def record_kind
      batch.stream == "activities" ? "activity" : "transaction"
    end

    def valid_removal_policy?(page)
      if batch.stream == "activities"
        page.removed_ids.empty? && page.coverage["removal_policy"].nil?
      else
        page.coverage["removal_policy"] == "exact_external_id"
      end
    end

    def source_record(id)
      SourceRecord.find_or_initialize_by(external_account: external_account, kind: record_kind, external_id: id) do |observation|
        observation.family_id = external_account.family_id
      end
    end

    def observe(record)
      metadata = (record[:metadata] || {}).with_indifferent_access
      unless metadata.fetch(:identity_occurrence, 0) == 0
        raise Provider::AccountData::UnsupportedCapability, "Unlinked connection changes require stable source identities"
      end
      observation = source_record(record[:external_id])
      return if observation.account_id.present?
      order = metadata.fetch(:observation_order, [])
      unless order.is_a?(Array) && order.all? { |value| value.is_a?(Integer) } &&
          (observation.observation_order.empty? || order.size == observation.observation_order.size)
        raise Provider::AccountData::InvalidResponse, "Retained observation ordering contract changed"
      end
      return if observation.observation_order.any? && (order <=> observation.observation_order) == -1
      observation.assign_attributes(ingestion_batch: batch, observation_order: order,
        pending: record_kind == "activity" ? false : record[:pending], withdrawn: false)
      observation.save!
    end
end
