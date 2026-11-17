class Tagging < ApplicationRecord
  belongs_to :tag
  belongs_to :taggable, polymorphic: true

  validate :tag_belongs_to_taggable_family, if: -> { tag_id.present? && taggable_type == "Transaction" }

  private
    # The family of a tagged transaction is its entry's account's. Compared in
    # memory when loaded, otherwise in one query.
    def tag_belongs_to_taggable_family
      transaction = taggable if association(:taggable).loaded?
      family_id = transaction&.loaded_family_id

      foreign = if family_id && association(:tag).loaded?
        tag.family_id != family_id
      else
        accounts = transaction ? transaction.owning_accounts : Transaction.owning_accounts(taggable_id)
        accounts.where.not(family_id: Tag.where(id: tag_id).select(:family_id)).exists?
      end

      errors.add(:tag, :invalid) if foreign
    end
end
