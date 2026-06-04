class AddTagToPockets < ActiveRecord::Migration[7.2]
  def change
    add_reference :pockets, :tag, type: :uuid, foreign_key: true, null: true
    add_index :pockets, [ :account_id, :tag_id ], unique: true, where: "tag_id IS NOT NULL",
              name: "index_pockets_on_account_and_tag_unique"
  end
end
