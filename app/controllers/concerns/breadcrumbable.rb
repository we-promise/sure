module Breadcrumbable
  extend ActiveSupport::Concern

  included do
    before_action :set_breadcrumbs
  end

  private
    # The default, unless specific controller or action explicitly overrides
    def set_breadcrumbs
      breadcrumb_key = "breadcrumbs.#{controller_name}"
      breadcrumb_text = I18n.t(breadcrumb_key, default: controller_name.titleize)
      @breadcrumbs = [ [ I18n.t("breadcrumbs.home"), root_path ], [ breadcrumb_text, nil ] ]
    end
end
