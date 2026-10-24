# iCost files and review notes may contain private financial and location data.
Rails.application.config.filter_parameters += [ :icost_import, :resolution ]
