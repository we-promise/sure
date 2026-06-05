class Tagging < ApplicationRecord
  belongs_to :tag
  belongs_to :taggable, polymorphic: true

  after_create :fill_linked_pocket
  before_destroy :unfill_linked_pocket

  private

    def fill_linked_pocket
      return unless (pocket = linked_pocket)
      # Fast path: skip without acquiring the lock if a sibling already exists.
      return if sibling_tagging_exists?

      # Re-check under a row lock to prevent concurrent duplicate taggings
      # (e.g. parallel re-imports) from double-incrementing the pocket.
      pocket.with_lock do
        next if sibling_tagging_exists?
        pocket.apply_tagging(self)
      end
    end

    def unfill_linked_pocket
      return unless (pocket = linked_pocket)
      return if sibling_tagging_exists?

      pocket.with_lock do
        next if sibling_tagging_exists?
        pocket.reverse_tagging(self)
      end
    end

    def sibling_tagging_exists?
      self.class.where(tag_id: tag_id, taggable_type: taggable_type, taggable_id: taggable_id)
                .where.not(id: id)
                .exists?
    end

    def linked_pocket
      return unless taggable_type == "Transaction"

      # taggable.entry traverses the has_one :entry on Transaction.
      # For AR-mediated destroys this is always populated (belongs_to dependent: :destroy
      # fires as before_destroy, so the Entry row is still present when this runs).
      # For raw SQL deletes (delete_all) the entry may be gone; the nil guard below
      # ensures we fail silently rather than raising.
      account = taggable.entry&.account
      return unless account

      account.pockets.find_by(tag_id: tag_id)
    end
end
