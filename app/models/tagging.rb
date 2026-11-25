class Tagging < ApplicationRecord
  belongs_to :tag
  belongs_to :taggable, polymorphic: true

  validate :tag_belongs_to_taggable_family, if: -> { taggable_type == "Transaction" && (tag_id.present? || association(:tag).loaded?) }

  private
    # The family of a tagged transaction is its entry's account's. A missing
    # tag is left to the belongs_to check. Compared in memory when loaded,
    # otherwise in one query.
    def tag_belongs_to_taggable_family
      transaction = taggable if association(:taggable).loaded?
      accounts = transaction ? transaction.owning_accounts : Transaction.owning_accounts(taggable_id)

      foreign = if association(:tag).loaded?
        return if tag.nil?

        family_id = transaction&.loaded_family_id
        family_id ? tag.family_id != family_id : accounts.where.not(family_id: tag.family_id).exists?
      else
        accounts.where.not(family_id: Tag.where(id: tag_id).select(:family_id)).exists?
      end

      errors.add(:tag, :invalid) if foreign
    end
end
