require_relative "../account_data"
require_relative "../../ingestion/record"

# Compatibility for integrations generated before values moved into Ingestion.
Provider::AccountData::Record = Ingestion::Record
