// The passkey ceremonies. Two requests each: fetch a challenge, hand back what
// the authenticator signed. WebAuthn moves bytes through JSON as base64url,
// which is all the encoding below is for.
(function () {
  var flows = {
    signup: { challenge: "/signup/challenge", finish: "/signup", kind: "create" },
    signin: { challenge: "/signin/challenge", finish: "/signin", kind: "get" },
    "add-passkey": {
      challenge: "/settings/passkeys/challenge",
      finish: "/settings/passkeys",
      kind: "create"
    }
  };

  function toBytes(value) {
    var padded = value.replace(/-/g, "+").replace(/_/g, "/");
    while (padded.length % 4 !== 0) padded += "=";
    var binary = atob(padded);
    var bytes = new Uint8Array(binary.length);
    for (var i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    return bytes;
  }

  function toText(buffer) {
    var bytes = new Uint8Array(buffer);
    var binary = "";
    for (var i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
    return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  }

  function csrf() {
    var meta = document.querySelector("meta[name=csrf-token]");
    return meta ? meta.getAttribute("content") : "";
  }

  function post(path, body) {
    return fetch(path, {
      method: "POST",
      credentials: "same-origin",
      headers: {
        "content-type": "application/json",
        accept: "application/json",
        "x-csrf-token": csrf()
      },
      body: JSON.stringify(body || {})
    }).then(function (response) {
      return response
        .json()
        .catch(function () {
          return {};
        })
        .then(function (json) {
          if (!response.ok) throw new Error(json.error || "request failed");
          return json;
        });
    });
  }

  function create(options) {
    options.challenge = toBytes(options.challenge);
    options.user.id = toBytes(options.user.id);
    (options.excludeCredentials || []).forEach(function (credential) {
      credential.id = toBytes(credential.id);
    });

    return navigator.credentials.create({ publicKey: options }).then(function (credential) {
      return {
        attestationObject: toText(credential.response.attestationObject),
        clientDataJSON: toText(credential.response.clientDataJSON)
      };
    });
  }

  function get(options) {
    options.challenge = toBytes(options.challenge);

    return navigator.credentials.get({ publicKey: options }).then(function (assertion) {
      return {
        id: toText(assertion.rawId),
        authenticatorData: toText(assertion.response.authenticatorData),
        signature: toText(assertion.response.signature),
        clientDataJSON: toText(assertion.response.clientDataJSON),
        userHandle: assertion.response.userHandle ? toText(assertion.response.userHandle) : null
      };
    });
  }

  function fields(form) {
    var body = {};
    Array.prototype.slice.call(form.querySelectorAll("input[name]")).forEach(function (input) {
      body[input.name] = input.value;
    });
    return body;
  }

  function run(form, flow) {
    var status = form.querySelector("[data-status]");
    var button = form.querySelector("button");

    function say(text) {
      if (status) status.textContent = text;
    }

    if (!window.PublicKeyCredential) {
      say("This browser has no passkey support.");
      return;
    }

    if (button) button.disabled = true;
    say("Waiting for your authenticator.");

    post(flow.challenge, fields(form))
      .then(function (json) {
        return flow.kind === "create" ? create(json.publicKey) : get(json.publicKey);
      })
      .then(function (answer) {
        return post(flow.finish, answer);
      })
      .then(function (json) {
        window.location = json.redirect || "/";
      })
      .catch(function (error) {
        if (button) button.disabled = false;
        say(error.name === "NotAllowedError" ? "Cancelled." : error.message);
      });
  }

  document.addEventListener("submit", function (event) {
    var form = event.target;
    var flow = flows[form.getAttribute("data-ceremony")];
    if (!flow) return;

    event.preventDefault();
    run(form, flow);
  });
})();
