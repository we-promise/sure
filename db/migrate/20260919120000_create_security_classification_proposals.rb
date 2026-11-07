class CreateSecurityClassificationProposals < ActiveRecord::Migration[8.1]
  def change
    create_table :security_classification_proposals, id: :uuid do |t|
      t.references :security, null: false, foreign_key: true, type: :uuid
      t.references :family, null: false, foreign_key: true, type: :uuid

      # The same four columns `securities` carries, holding what was PROPOSED
      # rather than what is true. Nullable individually: a proposal that can only
      # answer the region is still worth reviewing.
      t.string :asset_class
      t.string :asset_sub_class
      t.string :sector
      t.string :region

      t.text :rationale
      t.string :status, null: false, default: "pending"

      t.timestamps
    end

    # One live proposal per security per family. Re-proposing replaces rather
    # than accumulating, so a review screen cannot show the same security twice
    # with two different answers.
    add_index :security_classification_proposals,
              [ :family_id, :security_id ],
              unique: true,
              name: "idx_classification_proposals_on_family_and_security"

    add_check_constraint :security_classification_proposals,
                         "status IN ('pending', 'approved', 'rejected')",
                         name: "chk_classification_proposals_status"
  end
end
