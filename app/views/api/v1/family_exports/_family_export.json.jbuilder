# frozen_string_literal: true

json.id family_export.id
json.status family_export.status
json.filename family_export.filename
json.downloadable family_export.downloadable?
json.download_path family_export.downloadable? ? download_api_v1_family_export_path(family_export) : nil
attached = family_export.export_file.attached?
json.file do
  json.attached attached
  json.byte_size attached ? family_export.export_file.byte_size : nil
  json.content_type attached ? family_export.export_file.content_type : nil
end
json.created_at family_export.created_at
json.updated_at family_export.updated_at
