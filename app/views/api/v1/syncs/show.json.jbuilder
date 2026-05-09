# frozen_string_literal: true

json.data do
  if @sync
    json.partial! "api/v1/syncs/sync", sync: @sync
  else
    json.nil!
  end
end
