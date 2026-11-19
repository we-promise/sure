# The import wizard's steps change an import before it is published. Guests
# may only change their own kind of import, and only before publishing. No one
# may change an import whose configuration is locked, or one already published.
module ImportGuestGuardable
  extend ActiveSupport::Concern

  private
    # The background import reads the file, account and choices as they are,
    # so once it is published (Import#claim_for_publish!) nothing changes them.
    def require_changeable_import
      return if @import.changeable_now?

      redirect_to import_path(@import), alert: t("imports.published_locked")
    end

    def require_import_editable!
      return require_non_guest! unless @import.editable_by?(Current.user)

      redirect_to import_path(@import), alert: t("imports.configuration_locked") if @import.configuration_locked?
    end
end
