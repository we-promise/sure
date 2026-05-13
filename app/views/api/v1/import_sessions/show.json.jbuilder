chunks = @import_session.imports.ordered_by_sequence.to_a

json.data do
  json.id @import_session.id
  json.type @import_session.import_type
  json.status @import_session.status
  json.client_session_id @import_session.client_session_id
  json.expected_chunks @import_session.expected_chunks
  json.chunks_count chunks.size
  json.summary @import_session.summary || {}
  json.error @import_session.error_details.presence
  json.created_at @import_session.created_at
  json.updated_at @import_session.updated_at

  json.chunks do
    json.array! chunks do |import|
      json.id import.id
      json.sequence import.sequence
      json.client_chunk_id import.client_chunk_id
      json.status import.status
      json.rows_count import.rows_count
      json.checksum import.checksum
      json.summary import.summary || {}
      json.error import.error_details.presence
      json.created_at import.created_at
      json.updated_at import.updated_at
    end
  end
end
