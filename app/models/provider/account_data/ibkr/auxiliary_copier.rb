# Compatibility entrypoint: existing IBKR archive/checkpoint identifiers and
# HMAC derivation remain unchanged when the shared logo implementation is used.
class Provider::AccountData::Ibkr::AuxiliaryCopier < Provider::AccountData::AuxiliaryCopier
  PROVIDER_KEYS = [ "ibkr" ].freeze
  FORMAT = "ibkr-logo-auxiliary/v1".freeze
  STREAM = "legacy_ibkr_auxiliary".freeze
  RETAINED_FORMAT = "ibkr-retained-auxiliary/v1".freeze
  BATCH_KEY_PREFIX = "ibkr-auxiliary".freeze
  KEY_SALT = "ibkr-auxiliary-manifest-v1".freeze
end
