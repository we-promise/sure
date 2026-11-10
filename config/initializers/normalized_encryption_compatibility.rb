# Apply the compatibility treatment before encrypted models load.
require Rails.root.join("lib/normalized_encryption_compatibility").to_s
NormalizedEncryptionCompatibility.install!
