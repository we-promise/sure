uploaded = local_assigns[:uploaded]
uploaded = import.uploaded? if uploaded.nil?
configured = local_assigns[:configured]
configured = import.configured_for_status_detail? if configured.nil?

json.uploaded uploaded
json.configured configured
json.terminal import.complete? || import.failed? || import.revert_failed?

if include_validation_stats
  valid_rows_count = local_assigns.fetch(:valid_rows_count)
  invalid_rows_count = local_assigns.fetch(:invalid_rows_count)

  cleaned = local_assigns[:cleaned]
  publishable = local_assigns[:publishable]
  cleaned = import.cleaned_from_validation_stats?(invalid_rows_count: invalid_rows_count) if cleaned.nil?
  publishable = import.publishable_from_validation_stats?(invalid_rows_count: invalid_rows_count) if publishable.nil?

  json.cleaned cleaned
  json.publishable publishable
  json.revertable import.revertable?
end
