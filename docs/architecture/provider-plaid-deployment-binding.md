# Plaid deployment binding

The legacy `PlaidItem` stores its US/EU region and access token but has no
environment or application-identity column. The regional `Configurable` fields
select database settings, environment variables, then the declared `sandbox`
default. Legacy clients can also retain a previously loaded
`Rails.application.config.plaid` or `plaid_eu` SDK configuration. Copying the item
alone therefore does not identify the deployment that will consume its token.

`Plaid::DeploymentBinding` captures this missing input during a quiesced copy.
The item archive's `auxiliary_inputs.plaid_deployment_binding` contains its exact
family, legacy UUID, upstream item ID, copy-run UUID, region, supported environment
and capture timestamp. Separate keyed fingerprints retain the client identity,
complete application credentials and item access token. Neither client ID nor
application secret nor access token is copied into this document. The original
token remains in its existing encrypted source archive and native credentials.

The copier projects the small document into connection settings and the selected
environment into `ProviderConnection.environment`. The archive remains the
authority. US and EU select separate fixed configuration classes; no payload or
metadata field names a settings key, environment variable, SDK class or endpoint.
Only `sandbox`, `development` and `production` are accepted. If the selected
legacy SDK configuration is already loaded, initial capture and preactivation
verification require its server index, client ID and secret to agree with current
configuration. These checks do not reload or mutate global SDK configuration.

Same-run bounded retries reuse the original binding and timestamp. A durable
capture-admission marker permits initial capture only for a newly established
quiesced run. Committing the item archive and mapping removes the marker in that
same transaction. A failure before item publication leaves it available for
retry. Shadow upgrades and explicitly authorized pre-proof restarts create a new
copy-run binding while retaining the prior archive chunks. An older interrupted
quiesced run without the marker cannot infer permission to bind itself to today's
application; it requires an eligible explicit restart or reconciliation.

Factory construction reads the checksummed retained item archive once. It checks
the archived binding against projected settings, original token/item/region,
current connection identity, copy-run provenance and current application values.
The Plaid adapter receives the validated binding as a frozen runtime input. Before
each provider request and before publication, existing runtime proof checks pin
the mapping descriptor, current settings, token and application fingerprints.
Those live checks do not repeatedly decrypt the archive. A native client is built
from its own admitted application values and does not depend on a retired legacy
SDK object's cache.

A changed client ID, application secret, token, environment, region, copied item
identity or retained proof fails closed. Even rotation of a secret for the same
client needs an explicit rebind protocol; this slice supplies no rebind command.
Fresh unmigrated connections continue to require explicit region/environment and
current application credentials. A copied connection cannot use that fresh-source
path to bypass a missing binding.

This is configuration provenance, not historical truth about Plaid's servers.
It does not prove that the token was originally issued for this application, test
the token upstream, accept the copied `next_cursor`, reconcile cached changes,
establish transaction coverage or enable native sync. Cursor/cache disposition,
credential-consumer fencing and migration activation remain independent gates.
The adapter remains disabled by its readiness declaration.

The binding is limited to 4 KiB; credential inputs have explicit length bounds.
Its fingerprints use the existing runtime-input application key with separate
purposes. Retaining or migrating that verification key is required during
application-key rotation, in addition to the original archive-checksum key. This
does not reuse the separately configured permanent financial-identity signing
keyring or claim that all migration evidence is ready for key rotation.

Behavioral tests cover both regions and all three environments, secret-free
documents, stale legacy SDK rejection, native independence from that SDK, source
and application drift, real quiesced copy consumption, request proof, retained
archive consistency, bounded input, same-run retry, shadow upgrade, explicit
restart and interrupted first capture. The current environment has no Ruby or
Bundler; these tests are written but have not been executed.
