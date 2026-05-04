function bufferToBase64url(buffer) {
  const bytes = new Uint8Array(buffer);
  const binary = String.fromCharCode(...bytes);

  return btoa(binary)
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/g, "");
}

function base64urlToBuffer(value) {
  const base64 = value.replace(/-/g, "+").replace(/_/g, "/");
  const padded = base64.padEnd(
    base64.length + ((4 - (base64.length % 4)) % 4),
    "=",
  );
  const binary = atob(padded);
  const bytes = new Uint8Array(binary.length);

  for (let i = 0; i < binary.length; i += 1) {
    bytes[i] = binary.charCodeAt(i);
  }

  return bytes.buffer;
}

export function prepareCredentialCreationOptions(options) {
  options.challenge = base64urlToBuffer(options.challenge);
  options.user.id = base64urlToBuffer(options.user.id);
  options.excludeCredentials = (options.excludeCredentials || []).map(
    (credential) => ({
      ...credential,
      id: base64urlToBuffer(credential.id),
    }),
  );

  return options;
}

export function prepareCredentialRequestOptions(options) {
  options.challenge = base64urlToBuffer(options.challenge);
  options.allowCredentials = (options.allowCredentials || []).map(
    (credential) => ({
      ...credential,
      id: base64urlToBuffer(credential.id),
    }),
  );

  return options;
}

export function serializePublicKeyCredential(credential) {
  const serialized = {
    id: credential.id,
    rawId: bufferToBase64url(credential.rawId),
    type: credential.type,
    authenticatorAttachment: credential.authenticatorAttachment,
    clientExtensionResults: credential.getClientExtensionResults(),
  };

  if (credential.response.attestationObject) {
    serialized.response = {
      attestationObject: bufferToBase64url(
        credential.response.attestationObject,
      ),
      clientDataJSON: bufferToBase64url(credential.response.clientDataJSON),
      transports: credential.response.getTransports
        ? credential.response.getTransports()
        : [],
    };
  } else {
    serialized.response = {
      authenticatorData: bufferToBase64url(
        credential.response.authenticatorData,
      ),
      clientDataJSON: bufferToBase64url(credential.response.clientDataJSON),
      signature: bufferToBase64url(credential.response.signature),
      userHandle: credential.response.userHandle
        ? bufferToBase64url(credential.response.userHandle)
        : null,
    };
  }

  return serialized;
}
