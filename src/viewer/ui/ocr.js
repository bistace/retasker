.pragma library

// Transcribe a captured PNG via an OpenRouter vision model. Pure functions:
// the QML layer supplies the config and decides what to do with the result
// (write the .txt and drop the .png, or keep the .png as-is).
//
// onResult is called with the transcribed text on success, or null when the
// note is unreadable or the request fails (offline) — in both cases the caller
// keeps the original image.

var UNREADABLE = "UNREADABLE";

function transcribe(pngUrl, cfg, onResult) {
    readBase64(pngUrl, function (b64) {
        if (!b64) {
            onResult(null);
            return;
        }
        postOcr(b64, cfg, onResult);
    });
}

// Read a local file into a base64 string (async).
function readBase64(url, onDone) {
    var xhr = new XMLHttpRequest();
    xhr.open("GET", url);
    xhr.responseType = "arraybuffer";
    xhr.onreadystatechange = function () {
        if (xhr.readyState !== XMLHttpRequest.DONE)
            return;
        onDone(xhr.response ? toBase64(xhr.response) : null);
    };
    xhr.send();
}

// Base64-encode the bytes directly. Qt.btoa mangles binary data (it re-encodes
// the string as text), which makes the provider reject the PNG, so we encode the
// raw bytes ourselves.
function toBase64(buffer) {
    var b = new Uint8Array(buffer);
    var chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    // Accumulate into an array and join once: `out += ...` per 3 bytes is O(n^2)
    // in engines without rope strings, which bites on larger PNGs.
    var parts = [];
    var i;
    for (i = 0; i + 2 < b.length; i += 3) {
        var n = (b[i] << 16) | (b[i + 1] << 8) | b[i + 2];
        parts.push(chars[(n >> 18) & 63] + chars[(n >> 12) & 63]
             + chars[(n >> 6) & 63] + chars[n & 63]);
    }
    var rem = b.length - i;
    if (rem === 1) {
        var n1 = b[i] << 16;
        parts.push(chars[(n1 >> 18) & 63] + chars[(n1 >> 12) & 63] + "==");
    } else if (rem === 2) {
        var n2 = (b[i] << 16) | (b[i + 1] << 8);
        parts.push(chars[(n2 >> 18) & 63] + chars[(n2 >> 12) & 63]
             + chars[(n2 >> 6) & 63] + "=");
    }
    return parts.join("");
}

function postOcr(b64, cfg, onResult) {
    var xhr = new XMLHttpRequest();
    xhr.open("POST", cfg.endpoint);
    xhr.setRequestHeader("Authorization", "Bearer " + cfg.apiKey);
    xhr.setRequestHeader("Content-Type", "application/json");
    xhr.onreadystatechange = function () {
        if (xhr.readyState === XMLHttpRequest.DONE)
            onResult(parseResult(xhr));
    };
    xhr.send(JSON.stringify(body(b64, cfg)));
}

function body(b64, cfg) {
    return {
        model: cfg.model,
        messages: [{
            role: "user",
            content: [
                { type: "text", text: cfg.prompt },
                { type: "image_url", image_url: { url: "data:image/png;base64," + b64 } }
            ]
        }]
    };
}

function parseResult(xhr) {
    if (xhr.status !== 200)
        return null;  // API/network error: keep the image
    var text;
    try {
        text = JSON.parse(xhr.responseText).choices[0].message.content.trim();
    } catch (e) {
        return null;
    }
    if (text === "" || text.indexOf(UNREADABLE) !== -1)
        return null;  // model couldn't read it: keep the image
    return text;
}
