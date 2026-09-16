# frozen_string_literal: true

class AddHistoryUnlockRequiredAtToFioItems < ActiveRecord::Migration[8.1]
  def change
    # Set when Fio refuses a statement period for want of a temporary full-history
    # unlock. While it is set, syncs stay inside the 90 days Fio serves without one
    # instead of spending their single request on a certain refusal.
    add_column :fio_items, :history_unlock_required_at, :datetime
  end
end
