module Breadcrumbable
  extend ActiveSupport::Concern

  included do
    before_action :set_breadcrumbs
  end

  private
    # The default, unless specific controller or action explicitly overrides
    # Stores i18n keys as symbols, resolved later in the view when locale is set
    def set_breadcrumbs
      @breadcrumbs = [ [ :"breadcrumbs.home", root_path ], [ :"breadcrumbs.#{controller_name}", nil ] ]
    end
end
