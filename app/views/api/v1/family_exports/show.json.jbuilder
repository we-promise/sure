# frozen_string_literal: true

json.data do
  json.partial! "api/v1/family_exports/family_export", family_export: @family_export
end
