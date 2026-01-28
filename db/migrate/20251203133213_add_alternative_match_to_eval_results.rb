class AddAlternativeMatchToEvalResults < ActiveRecord::Migration[7.2]
  def change
    add_column :eval_results, :alternative_match, :boolean, default: false
  end
end
