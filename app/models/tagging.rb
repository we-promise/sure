class Tagging < ApplicationRecord
  belongs_to :tag
  belongs_to :taggable, polymorphic: true

  after_create :fill_linked_pocket
  before_destroy :unfill_linked_pocket

  private

    def fill_linked_pocket
      # Skip if a sibling tagging for this same (tag, transaction) pair already exists —
      # duplicate taggings (e.g. from re-imports) must not double-increment the pocket.
      return if sibling_tagging_exists?
      linked_pocket&.apply_tagging(self)
    end

    def unfill_linked_pocket
      # Only unfill if this was the last tagging for this (tag, transaction) pair.
      return if sibling_tagging_exists?
      linked_pocket&.reverse_tagging(self)
    end

    def sibling_tagging_exists?
      self.class.where(tag_id: tag_id, taggable_type: taggable_type, taggable_id: taggable_id)
                .where.not(id: id)
                .exists?
    end

    def linked_pocket
      return unless taggable_type == "Transaction"

      account = taggable.entry&.account
      return unless account

      account.pockets.find_by(tag_id: tag_id)
    end
end
