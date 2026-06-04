class Tagging < ApplicationRecord
  belongs_to :tag
  belongs_to :taggable, polymorphic: true

  after_create :fill_linked_pocket
  before_destroy :unfill_linked_pocket

  private

    def fill_linked_pocket
      linked_pocket&.apply_tagging(self)
    end

    def unfill_linked_pocket
      linked_pocket&.reverse_tagging(self)
    end

    def linked_pocket
      return unless taggable_type == "Transaction"

      account = taggable.entry&.account
      return unless account

      account.pockets.find_by(tag_id: tag_id)
    end
end
