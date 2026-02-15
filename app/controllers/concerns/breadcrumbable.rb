module Breadcrumbable
  extend ActiveSupport::Concern

  included do
    before_action :set_breadcrumbs
  end

  private
    # The default, unless specific controller or action explicitly overrides
    def set_breadcrumbs
      # Use I18n to get the breadcrumb label based on controller name, with a fallback to titleized controller name
      @breadcrumbs = [ [ t("layouts.application.nav.home"), root_path ], [ t("breadcrumbs.#{controller_name}", default: controller_name.titleize), nil ]
 ]
    end
end
