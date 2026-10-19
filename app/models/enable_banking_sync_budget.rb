# frozen_string_literal: true

class EnableBankingSyncBudget < ApplicationRecord
  BACKGROUND_INTERVAL = 6.hours
  DATA_REQUEST_INTERVAL = 1.second

  belongs_to :family

  validates :bank_key, presence: true, length: { is: 64 }

  def self.for_item(item)
    bank_key = item.sync_budget_key
    return unless bank_key

    scope = where(family_id: item.family_id, bank_key: bank_key)
    scope.first || create_or_find_by!(family_id: item.family_id, bank_key: bank_key) do |budget|
      budget.seed_from_existing_attempts!(item)
    end
  end

  def with_bank_lock
    lock_key = Digest::SHA256.hexdigest("enable-banking-bank:#{family_id}:#{bank_key}").first(15).to_i(16)

    self.class.connection_pool.with_connection do |connection|
      locked = connection.select_value("SELECT pg_try_advisory_lock(#{lock_key})")
      raise EnableBankingItem::SyncScheduling::SyncDeferredError, "A bank refresh is already in progress." unless locked == true || locked.to_s == "t"

      begin
        yield
      ensure
        connection.execute("SELECT pg_advisory_unlock(#{lock_key})")
      end
    end
  end

  def reserve_for_sync!(item:, online:, at: Time.current)
    with_lock do
      reload
      active_sync = Sync.find_by(id: active_sync_id) if active_sync_id.present?
      active_sync_visible = (active_sync&.syncing? && active_sync.updated_at > Sync::VISIBLE_FOR.ago) ||
        (active_sync&.pending? && active_sync.created_at > Sync::VISIBLE_FOR.ago && active_sync.cancel_requested_at.nil?)
      if active_sync_visible
        return false unless active_sync.syncable_type == item.class.base_class.name && active_sync.syncable_id == item.id

        sync = yield
        return false unless sync&.id == active_sync.id

        update!(active_sync_online: active_sync_online || online)
        return sync
      end

      return false if rate_limited_until.present? && rate_limited_until > at
      return false if !online && next_background_sync_at.present? && next_background_sync_at > at

      sync = yield
      return false unless sync

      update!(
        active_sync_id: sync.id,
        active_sync_online: online
      )
      sync
    end
  end

  def reserve_execution!(sync, online:, at: Time.current)
    with_lock do
      reload
      return false unless active_sync_id == sync.id
      return false if rate_limited_until.present? && rate_limited_until > at
      return false if !online && next_background_sync_at.present? && next_background_sync_at > at

      update!(next_background_sync_at: [ next_background_sync_at, at + BACKGROUND_INTERVAL ].compact.max)
      true
    end
  end

  def release_sync!(sync)
    with_lock do
      reload
      return unless active_sync_id == sync.id

      update!(active_sync_id: nil, active_sync_online: false)
    end
  end

  def extend_rate_limit!(deadline)
    return unless deadline

    with_lock do
      reload
      update!(rate_limited_until: [ rate_limited_until, deadline ].compact.max)
    end
  end

  def wait_for_data_request_slot!
    with_lock do
      reload
      wait_seconds = DATA_REQUEST_INTERVAL - (Time.current - last_data_request_at) if last_data_request_at.present?
      sleep(wait_seconds) if wait_seconds&.positive?
      update!(last_data_request_at: Time.current)
    end
  end

  def background_due?(at: Time.current)
    next_background_sync_at.blank? || next_background_sync_at <= at
  end

  def seed_from_existing_attempts!(item)
    siblings = EnableBankingItem.where(
      family_id: item.family_id,
      application_id: item.application_id,
      aspsp_name: item.aspsp_name,
      country_code: item.country_code
    )
    sibling_ids = siblings.select(:id)
    latest_attempt_at = Sync.where(syncable_type: "EnableBankingItem", syncable_id: sibling_ids).maximum(:created_at)
    existing_item_deadline = siblings.maximum(:next_sync_at)
    legacy_hard_deadline = siblings.where(sync_retry_reason: "rate_limited").maximum(:next_sync_at)
    active_sync = Sync.visible.where(syncable_type: "EnableBankingItem", syncable_id: sibling_ids)
      .order(created_at: :desc, id: :desc).first

    self.next_background_sync_at = [ latest_attempt_at && latest_attempt_at + BACKGROUND_INTERVAL,
                                     existing_item_deadline ].compact.max
    self.rate_limited_until = legacy_hard_deadline
    self.last_data_request_at = latest_attempt_at
    self.active_sync_id = active_sync&.id
    self.active_sync_online = false
    end
end
