require "bigdecimal"
require "digest"
require "json"
require "time"

class ScalableItem::HistoryImporter
  SOURCE = "scalable".freeze
  EXTERNAL_ID_PREFIX = "scalable-history-v1:".freeze
  EXTERNAL_ID_PATTERN = /\A#{Regexp.escape(EXTERNAL_ID_PREFIX)}[a-f0-9]{64}\z/.freeze
  MAX_NAME_BYTES = 512
  MAX_SOURCE_ID_BYTES = 256
  MAX_AMOUNT = BigDecimal("1000000000000000")
  HISTORY_METADATA_KEYS = %w[cash_transaction_type source_id status].freeze
  CASH_TRANSACTION_TYPES = %w[DEPOSIT WITHDRAWAL].freeze

  HistoryRow = Data.define(:activity, :amount, :metadata)

  def initialize(item)
    @item_id = item.id
    @owner_id = item.owner_id
    @family_id = item.family_id
    @person_identity = item.person_identity.to_s
    @connection_generation = item.connection_generation
  end

  def import(provider_account:, normalized:)
    activities = validate_normalized!(normalized)
    account = nil
    changed = false

    ApplicationRecord.transaction(requires_new: true) do
      owner = User.find_by(id: @owner_id, family_id: @family_id)
      raise Provider::Scalable::Error.new(:account_identity_changed) unless owner&.active?

      owner.with_lock do
        item = ScalableItem.find_by(id: @item_id, owner_id: @owner_id, family_id: @family_id)
        raise Provider::Scalable::Error.new(:account_identity_changed) unless item

        item.with_lock do
          validate_current_identity!(item)
          locked_provider_account = item.scalable_accounts.lock.find_by(id: provider_account.id)
          unless locked_provider_account && locked_provider_account.uid == provider_account.uid
            raise Provider::Scalable::Error.new(:account_conflict)
          end

          account = validate_account_binding!(item, locked_provider_account)
          validate_external_ids!(activities, locked_provider_account.uid)
          reject_disappeared_history!(account, activities)
          reject_type_collisions!(account, activities)

          adapter = Account::ProviderImportAdapter.new(account)
          activities.each do |row|
            entry = adapter.import_transaction(
              external_id: row.activity.external_id,
              amount: row.amount,
              currency: row.activity.currency,
              date: row.activity.date,
              name: row.activity.name,
              source: SOURCE,
              kind: "funds_movement",
              investment_activity_label: activity_label(row.metadata.fetch("cash_transaction_type")),
              extra: { "scalable" => row.metadata },
              allow_heuristic_matching: false,
              replace_extra_namespaces: [ SOURCE ]
            )
            changed ||= entry.saved_changes_affect_balances?
          end

          anchor_result = account.ensure_opening_anchor_precedes_entries
          changed ||= anchor_result&.changes_made?
          update_history_metadata!(locked_provider_account, activities)
        end
      end
    end

    ActiveRecord.after_all_transactions_commit { account.sync_later } if changed
    activities.length
  rescue Provider::Scalable::Error
    raise
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique, ActiveRecord::RecordNotFound
    raise Provider::Scalable::Error.new(:account_conflict), cause: nil
  end

  private

    def validate_normalized!(normalized)
      unless normalized.is_a?(ScalableItem::HistoryNormalizer::Result) && normalized.activities.is_a?(Array) &&
          normalized.activities.all? { |activity| activity.is_a?(ScalableItem::HistoryNormalizer::Activity) }
        raise Provider::Scalable::Error.new(:history_incomplete)
      end

      rows = normalized.activities.map { |activity| normalize_activity(activity) }
      ids = rows.map { |row| row.activity.external_id }
      source_ids = rows.map { |row| row.metadata.fetch("source_id") }
      unless ids.uniq.length == ids.length && source_ids.uniq.length == source_ids.length
        raise Provider::Scalable::Error.new(:history_incomplete)
      end

      rows.freeze
    end

    def normalize_activity(activity)
      metadata = normalized_metadata(activity.metadata)
      amount = normalized_amount(activity.amount)
      direction_matches = case metadata.fetch("cash_transaction_type")
      when "DEPOSIT" then amount&.negative?
      when "WITHDRAWAL" then amount&.positive?
      else false
      end
      valid = activity.external_id.is_a?(String) && activity.external_id.valid_encoding? &&
        activity.external_id.match?(EXTERNAL_ID_PATTERN) &&
        activity.date.instance_of?(Date) && activity.date > Entry.min_supported_date && activity.date <= Date.current &&
        activity.currency == ScalableAccount::BROKER_CURRENCY && valid_name?(activity.name) && amount.present? &&
        direction_matches
      raise Provider::Scalable::Error.new(:history_incomplete) unless valid

      HistoryRow.new(activity: activity, amount: amount, metadata: metadata.freeze)
    end

    def normalized_metadata(value)
      raise Provider::Scalable::Error.new(:history_incomplete) unless value.is_a?(Hash)

      metadata = value.deep_stringify_keys
      valid = metadata.keys.sort == HISTORY_METADATA_KEYS &&
        CASH_TRANSACTION_TYPES.include?(metadata["cash_transaction_type"]) &&
        %w[SETTLED CONFIRMED].include?(metadata["status"]) &&
        metadata["source_id"].is_a?(String) && metadata["source_id"].valid_encoding? && metadata["source_id"].present? &&
        metadata["source_id"].bytesize <= MAX_SOURCE_ID_BYTES &&
        !metadata["source_id"].match?(/[\u0000-\u001F\u007F]/)
      raise Provider::Scalable::Error.new(:history_incomplete) unless valid

      metadata
    end

    def normalized_amount(value)
      return unless value.is_a?(Numeric)

      amount = BigDecimal(value.to_s)
      return unless amount.finite? && !amount.zero? && amount.abs < MAX_AMOUNT && amount == amount.round(4)

      amount
    rescue ArgumentError, TypeError
      nil
    end

    def valid_name?(value)
      value.is_a?(String) && value.valid_encoding? && value.present? && value.bytesize <= MAX_NAME_BYTES &&
        !value.match?(/[\u0000-\u001F\u007F]/)
    end

    def validate_current_identity!(item)
      valid = item.connected? && item.ready_for_sync? && item.owner_id == @owner_id && item.family_id == @family_id &&
        item.person_identity.to_s == @person_identity && item.connection_generation == @connection_generation
      raise Provider::Scalable::Error.new(:account_identity_changed) unless valid
    end

    def validate_account_binding!(item, provider_account)
      metadata = JSON.parse(provider_account.raw_metadata.to_s)
      valid_metadata = metadata.is_a?(Hash) && metadata["portfolio_id"] == provider_account.uid &&
        metadata["account_id"].is_a?(String) && metadata["account_id"].present? &&
        metadata["person_identity"].to_s == @person_identity
      account = provider_account.usable_account
      provider_link = provider_account.account_provider
      valid_link = provider_account.scalable_item_id == item.id && provider_account.broker? &&
        provider_account.currency == ScalableAccount::BROKER_CURRENCY && account && provider_link &&
        provider_link.provider_type == "ScalableAccount" && provider_link.provider_id == provider_account.id &&
        account.account_providers.where.not(id: provider_link.id).none?
      raise Provider::Scalable::Error.new(:account_conflict) unless valid_metadata && valid_link

      account
    rescue JSON::ParserError
      raise Provider::Scalable::Error.new(:account_conflict), cause: nil
    end

    def validate_external_ids!(activities, portfolio_id)
      valid = activities.all? do |row|
        digest = Digest::SHA256.hexdigest(JSON.generate([ portfolio_id, row.metadata.fetch("source_id") ]))
        row.activity.external_id == "#{EXTERNAL_ID_PREFIX}#{digest}"
      end
      raise Provider::Scalable::Error.new(:history_incomplete) unless valid
    end

    def reject_disappeared_history!(account, activities)
      incoming_ids = activities.map { |row| row.activity.external_id }
      existing_ids = account.entries.where(source: SOURCE)
        .where("external_id LIKE ?", "#{EXTERNAL_ID_PREFIX}%")
        .pluck(:external_id)
      raise Provider::Scalable::Error.new(:history_changed) unless (existing_ids - incoming_ids).empty?
    end

    def reject_type_collisions!(account, activities)
      activities.each do |row|
        entry = account.entries.find_by(source: SOURCE, external_id: row.activity.external_id)
        next unless entry && !entry.transaction?

        raise Provider::Scalable::Error.new(:account_conflict)
      end
    end

    def activity_label(cash_transaction_type)
      cash_transaction_type == "DEPOSIT" ? "Transfer" : "Withdrawal"
    end

    def update_history_metadata!(provider_account, activities)
      metadata = JSON.parse(provider_account.raw_metadata.to_s)
      raise Provider::Scalable::Error.new(:account_conflict) unless metadata.is_a?(Hash)

      metadata["history"] = {
        "schema_version" => 1,
        "synced_at" => Time.current.utc.iso8601,
        "count" => activities.length,
        "first_date" => activities.map { |row| row.activity.date }.min&.iso8601
      }
      provider_account.update!(raw_metadata: JSON.generate(metadata))
    rescue JSON::ParserError
      raise Provider::Scalable::Error.new(:account_conflict), cause: nil
    end
end
