class AddReplayRequestedAtToPlaidItems < ActiveRecord::Migration[7.2]
  # Records that a connection owes a full-history fetch, so a naming-preference
  # change reaches transactions that already exist. Durable on purpose: it
  # outlives worker restarts and long syncs, and is cleared only once a sync has
  # actually replayed the history it asks for.
  #
  # @return [void]
  def change
    add_column :plaid_items, :replay_requested_at, :datetime
  end
end
