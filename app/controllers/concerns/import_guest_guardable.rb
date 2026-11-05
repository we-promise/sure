# The import wizard's steps change an import before it is published. Guests
# may only change their own kind of import, and only before publishing.
module ImportGuestGuardable
  extend ActiveSupport::Concern

  private
    def require_import_editable!
      require_non_guest! unless @import.editable_by?(Current.user)
    end
end
