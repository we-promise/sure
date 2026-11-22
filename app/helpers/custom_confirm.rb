# The shape of data expected by `confirm_dialog_controller.js` to override the
# default browser confirm API via Turbo. The dialog renders every field as text,
# so record names can be interpolated as they are.
class CustomConfirm
  class << self
    # A record's own name (email, tag, merchant) is shown as stored.
    def for_resource_deletion(resource_name, high_severity: false)
      deletion(resource_name, high_severity: high_severity)
    end

    # An English noun literal ("rule", "all tags") keeps the titleized heading
    # and downcased body.
    def for_noun_deletion(noun, high_severity: false)
      deletion(noun.titleize, high_severity: high_severity, body_resource: noun.downcase)
    end

    private
      def deletion(resource, high_severity:, body_resource: resource)
        new(
          destructive: true,
          high_severity: high_severity,
          title: I18n.t("shared.custom_confirm.resource_deletion_title", resource: resource),
          body: I18n.t("shared.custom_confirm.resource_deletion_body", resource: body_resource),
          btn_text: I18n.t("shared.custom_confirm.resource_deletion_btn_text", resource: resource)
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
