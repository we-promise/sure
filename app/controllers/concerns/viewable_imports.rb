# Imports belong to the family, but one made from a statement is as private as
# that statement. Import pages look imports up through here.
module ViewableImports
  extend ActiveSupport::Concern

  private
    def viewable_imports
      Current.family.imports.viewable_by(Current.user)
    end
end
