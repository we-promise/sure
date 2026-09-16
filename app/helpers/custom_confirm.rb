# The shape of data expected by `confirm_dialog_controller.js` to override the
# default browser confirm API via Turbo.
class CustomConfirm
  class << self
    # `body` is the one field the dialog renders as HTML — confirm_dialog_controller
    # assigns it to innerHTML so bodies such as accounts' `confirm_body_html` can
    # carry markup, while title and button label go through textContent. Every
    # caller passes a user-named record here, so the name is escaped on its way
    # into the body: without it a record named "<img src=x onerror=…>" executes
    # as soon as someone opens the confirmation.
    # `titleize` / `downcase` are English-shaped and stay applied to the record
    # name so the English copy is unchanged; a locale that needs different
    # casing can absorb it in its own string.
    def for_resource_deletion(resource_name, high_severity: false)
      new(
        destructive: true,
        high_severity: high_severity,
        title: I18n.t("shared.custom_confirm.resource_deletion_title", resource: resource_name.titleize),
        # Escaped, unlike the other two: this is the only field the dialog
        # renders as HTML.
        body: I18n.t("shared.custom_confirm.resource_deletion_body", resource: ERB::Util.html_escape(resource_name.downcase)),
        btn_text: I18n.t("shared.custom_confirm.resource_deletion_btn_text", resource: resource_name.titleize)
      )
    end
  end

  def initialize(title: default_title, body: default_body, btn_text: default_btn_text, destructive: false, high_severity: false)
    @title = title
    @body = body
    @btn_text = btn_text
    @btn_variant = derive_btn_variant(destructive, high_severity)
  end

  def to_data_attribute
    {
      title: title,
      body: body,
      confirmText: btn_text,
      variant: btn_variant
    }
  end

  private
    attr_reader :title, :body, :btn_text, :btn_variant

    def derive_btn_variant(destructive, high_severity)
      return "primary" unless destructive
      high_severity ? "destructive" : "outline-destructive"
    end

    def default_title
      I18n.t("shared.custom_confirm.default_title")
    end

    def default_body
      I18n.t("shared.custom_confirm.default_body")
    end

    def default_btn_text
      I18n.t("shared.custom_confirm.default_btn_text")
    end
end
