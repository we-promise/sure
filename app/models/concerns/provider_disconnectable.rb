# What happens to imported financial data when a provider connection goes away.
#
# Disconnecting has always meant one thing in this app: revoke the credential,
# drop the AccountProvider links, and leave every account, balance and
# transaction where it is. That is the right default -- the data describes the
# family's money, not the connection that fetched it, and a reconnect should
# find its history intact. But it is not the only thing a family may want. A
# person who connects a wallet, sees a year of card spending appear, and decides
# against it is asking for the import to be undone, not parked.
#
# So a disconnect carries a disposition:
#
#   retain  -- revoke the connection, keep the imported data. Every provider
#              supports this, and it stays the default: a caller that says
#              nothing gets the behaviour it has always got.
#   discard -- revoke the connection and remove what it imported. Destructive
#              and irreversible, so a provider has to implement it deliberately
#              and declare that it has.
#
# Providers opt in with `self.supports_discard = true`. The default is false, so
# an unconverted provider reports only `retain` and rejects `discard` instead of
# silently accepting it and keeping the data -- the failure mode that would
# matter here is a family being told their data was deleted when it was not.
#
# The vocabulary lives here rather than in any one provider because it is a
# contract with API clients: FinanceKit's capabilities response advertises the
# dispositions this build supports, and a client feature-detects rather than
# hardcoding. Adding a second provider should not change the wire format.
module ProviderDisconnectable
  extend ActiveSupport::Concern

  RETAIN = "retain"
  DISCARD = "discard"
  DISPOSITIONS = [ RETAIN, DISCARD ].freeze
  DEFAULT_DISPOSITION = RETAIN

  included do
    class_attribute :supports_discard, instance_writer: false, default: false
  end

  class_methods do
    def supported_dispositions
      supports_discard ? DISPOSITIONS : [ DEFAULT_DISPOSITION ]
    end
  end

  def supported_dispositions
    self.class.supported_dispositions
  end

  def disposition_supported?(disposition)
    supported_dispositions.include?(disposition.to_s)
  end

  # Normalizes a caller-supplied disposition, or raises. Callers that answer to
  # an API translate this into their own typed error: the concern has no opinion
  # about status codes.
  def disposition!(disposition)
    value = disposition.presence&.to_s || DEFAULT_DISPOSITION
    unless disposition_supported?(value)
      raise ArgumentError, "unsupported disconnect disposition: #{value.inspect}"
    end

    value
  end

  def discarding?(disposition)
    disposition!(disposition) == DISCARD
  end
end
