# YAXI browser dependency

The YAXI integration uses `routex-client` because bank credentials must travel
directly from the browser through YAXI's encrypted channel. Reimplementing that
protocol in Sure would duplicate security-critical cryptography and service-flow
handling.

- Package: `routex-client`
- Bundled version: `0.6.0`
- Source: <https://www.npmjs.com/package/routex-client>
- Local artifact: `vendor/javascript/routex-client.js`
- Import map entry: `config/importmap.rb`
- License: npm marks the package as `UNLICENSED`; redistribution therefore
  requires permission through the applicable YAXI agreement.

The package is bundled locally so credentials are not exposed to a third-party
CDN and production does not depend on an external asset host. To update it,
verify the target version and its license with YAXI, rebuild the browser bundle,
replace the local artifact, update the pinned version comment, and run the
JavaScript tests, Biome, and Brakeman before committing.
