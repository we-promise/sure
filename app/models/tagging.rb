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

      # taggable.entry may be nil if the Entry row was already deleted
      # (e.g. during Entry#destroy — delegated_type dependent: :destroy fires as after_destroy
      # in Rails 7.2, so Entry is gone before Transaction/Taggings cascade).
      # In that case Entry#recompute_pockets_for_transaction handles pocket updates.
      account = taggable.entry&.account
      return unless account

      account.pockets.find_by(tag_id: tag_id)
    end
end
