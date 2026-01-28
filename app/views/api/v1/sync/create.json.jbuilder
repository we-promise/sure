# frozen_string_literal: true

json.id @sync.id
json.status @sync.status
json.syncable_type @sync.syncable_type
json.syncable_id @sync.syncable_id
json.syncing_at @sync.syncing_at
json.completed_at @sync.completed_at
json.window_start_date @sync.window_start_date
json.window_end_date @sync.window_end_date
json.message "Sync has been queued and will apply all active rules"
