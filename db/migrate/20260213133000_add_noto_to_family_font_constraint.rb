class AddNotoToFamilyFontConstraint < ActiveRecord::Migration[7.2]
  def change
    remove_check_constraint :families, name: "families_font_allowed_values"
    add_check_constraint :families, "font IN ('sans', 'display', 'mono', 'noto')", name: "families_font_allowed_values"
  end
end
