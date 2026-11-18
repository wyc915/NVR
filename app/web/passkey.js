// WebAuthn (passkey / Face ID) helpers for the Flutter web app.
// Options and results cross the Dart <-> JS boundary as JSON strings
// (the server's options use base64url for all binary fields).
(function () {
  'use strict';

  function enc(buf) {
    var bytes = new Uint8Array(buf);
    var s = '';
    for (var i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
    return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  }

  function dec(str) {
    var s = str.replace(/-/g, '+').replace(/_/g, '/');
    while (s.length % 4) s += '=';
    var bin = atob(s);
    var out = new Uint8Array(bin.length);
    for (var i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out.buffer;
  }

  function creds(list) {
    return (list || []).map(function (c) {
      return { id: dec(c.id), type: c.type, transports: c.transports };
    });
  }

  window.nvrPasskey = {
    supported: function () {
      return !!(window.PublicKeyCredential && navigator.credentials && window.isSecureContext);
    },

    // Must be called directly from a tap handler (Safari needs a user gesture).
    create: function (json) {
      var o = JSON.parse(json);
      o.challenge = dec(o.challenge);
      o.user.id = dec(o.user.id);
      o.excludeCredentials = creds(o.excludeCredentials);
      return navigator.credentials.create({ publicKey: o }).then(function (c) {
        var r = c.response;
        return JSON.stringify({
          id: c.id,
          rawId: enc(c.rawId),
          type: c.type,
          authenticatorAttachment: c.authenticatorAttachment || undefined,
          clientExtensionResults: c.getClientExtensionResults(),
          response: {
            clientDataJSON: enc(r.clientDataJSON),
            attestationObject: enc(r.attestationObject),
            transports: r.getTransports ? r.getTransports() : [],
          },
        });
      });
    },

    get: function (json) {
      var o = JSON.parse(json);
      o.challenge = dec(o.challenge);
      o.allowCredentials = creds(o.allowCredentials);
      return navigator.credentials.get({ publicKey: o }).then(function (c) {
        var r = c.response;
        return JSON.stringify({
          id: c.id,
          rawId: enc(c.rawId),
          type: c.type,
          authenticatorAttachment: c.authenticatorAttachment || undefined,
          clientExtensionResults: c.getClientExtensionResults(),
          response: {
            clientDataJSON: enc(r.clientDataJSON),
            authenticatorData: enc(r.authenticatorData),
            signature: enc(r.signature),
            userHandle: r.userHandle ? enc(r.userHandle) : undefined,
          },
        });
      });
    },
  };
})();
