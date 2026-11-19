# The import wizard's steps change an import before it is published. Guests
# may only change their own kind of import, and only before publishing. No one
# may change an import whose configuration is locked, or one already published.
module ImportGuestGuardable
  extend ActiveSupport::Concern

  private
    # around_action for the actions that change an import. The background
    # import reads the file, account and choices as they are, so the edit
    # holds the lock a publish takes (Import#with_publish_lock) and runs only
    # while the import is still changeable.
    def lock_changeable_import
      @import.with_publish_lock do
        if @import.reload.changeable?
          yield
        else
          redirect_to import_path(@import), alert: t("imports.published_locked")
        end
      end
    rescue Import::PublishBusyError
      redirect_to import_path(@import), alert: t("imports.publish_busy")
    end

    def require_import_editable!
      return require_non_guest! unless @import.editable_by?(Current.user)

      redirect_to import_path(@import), alert: t("imports.configuration_locked") if @import.configuration_locked?
    end
end
