class Tagging < ApplicationRecord
  belongs_to :tag
  belongs_to :taggable, polymorphic: true

  validate :tag_belongs_to_taggable_family

  private
    # The family of a tagged transaction is its entry's account's.
    def tag_belongs_to_taggable_family
      family_id = taggable.try(:entry)&.account&.family_id
      errors.add(:tag, :invalid) if tag && family_id && tag.family_id != family_id
    end
end
