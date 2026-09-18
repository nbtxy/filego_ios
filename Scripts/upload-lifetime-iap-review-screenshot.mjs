#!/usr/bin/env node
import { createHash, createPrivateKey, createSign } from "node:crypto";
import { basename, resolve } from "node:path";
import { readFileSync } from "node:fs";

const IAP_ID = "6812208070";
const IMAGE_PATH = resolve("fastlane/screenshots/zh-Hans/04-pro-lifetime.png");
const image = readFileSync(IMAGE_PATH);
const checksum = createHash("md5").update(image).digest("hex");

function b64url(value) { return Buffer.from(value).toString("base64url"); }
function derToP1363(der) {
  let offset = 2;
  if (der[1] & 0x80) offset = 2 + (der[1] & 0x7f);
  const rLength = der[offset + 1];
  const r = der.subarray(offset + 2, offset + 2 + rLength);
  const sOffset = offset + 2 + rLength;
  const sLength = der[sOffset + 1];
  const s = der.subarray(sOffset + 2, sOffset + 2 + sLength);
  const fixed = (part) => {
    const output = Buffer.alloc(32);
    const trimmed = part[0] === 0 ? part.subarray(1) : part;
    trimmed.copy(output, 32 - trimmed.length);
    return output;
  };
  return Buffer.concat([fixed(r), fixed(s)]);
}
function token() {
  const keyId = process.env.ASC_KEY_ID;
  const issuer = process.env.ASC_ISSUER_ID;
  const path = process.env.ASC_KEY_FILEPATH;
  if (!keyId || !issuer || !path) throw new Error("缺少 ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_FILEPATH");
  const now = Math.floor(Date.now() / 1000);
  const header = b64url(JSON.stringify({ alg: "ES256", kid: keyId, typ: "JWT" }));
  const payload = b64url(JSON.stringify({ iss: issuer, iat: now, exp: now + 600, aud: "appstoreconnect-v1" }));
  const signer = createSign("SHA256");
  signer.update(`${header}.${payload}`);
  const signature = signer.sign(createPrivateKey(readFileSync(path, "utf8")));
  return `${header}.${payload}.${b64url(derToP1363(signature))}`;
}
async function asc(method, path, body) {
  const response = await fetch(`https://api.appstoreconnect.apple.com${path}`, {
    method,
    headers: { Authorization: `Bearer ${token()}`, ...(body ? { "Content-Type": "application/json" } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
  const parsed = await response.json().catch(() => null);
  if (!response.ok) throw new Error(`${method} ${path} -> ${response.status}\n${JSON.stringify(parsed?.errors ?? parsed, null, 2)}`);
  return parsed;
}
function stateOf(resource) {
  return resource.attributes.assetDeliveryState?.state ?? "UNKNOWN";
}

const existing = await asc("GET", `/v2/inAppPurchases/${IAP_ID}/appStoreReviewScreenshot`).catch((error) => {
  if (error.message.includes("-> 404")) return null;
  throw error;
});
if (existing?.data?.attributes?.sourceFileChecksum === checksum && stateOf(existing.data) === "COMPLETE") {
  console.log(`review screenshot already current: ${existing.data.id}`);
  process.exit(0);
}

const reservation = await asc("POST", "/v1/inAppPurchaseAppStoreReviewScreenshots", {
  data: {
    type: "inAppPurchaseAppStoreReviewScreenshots",
    attributes: { fileSize: image.length, fileName: basename(IMAGE_PATH) },
    relationships: { inAppPurchaseV2: { data: { type: "inAppPurchases", id: IAP_ID } } },
  },
});
const resource = reservation.data;
for (const operation of resource.attributes.uploadOperations) {
  const headers = Object.fromEntries(operation.requestHeaders.map((header) => [header.name, header.value]));
  const response = await fetch(operation.url, {
    method: operation.method,
    headers,
    body: image.subarray(operation.offset, operation.offset + operation.length),
  });
  if (!response.ok) throw new Error(`上传审核截图分片失败：${response.status} ${await response.text()}`);
}
await asc("PATCH", `/v1/inAppPurchaseAppStoreReviewScreenshots/${resource.id}`, {
  data: {
    type: "inAppPurchaseAppStoreReviewScreenshots",
    id: resource.id,
    attributes: { uploaded: true, sourceFileChecksum: checksum },
  },
});
for (let attempt = 0; attempt < 20; attempt += 1) {
  const current = (await asc("GET", `/v1/inAppPurchaseAppStoreReviewScreenshots/${resource.id}`)).data;
  const state = stateOf(current);
  if (state === "COMPLETE") {
    console.log(`review screenshot complete: ${resource.id}`);
    process.exit(0);
  }
  if (state === "FAILED") throw new Error(JSON.stringify(current.attributes, null, 2));
  await new Promise((resolvePromise) => setTimeout(resolvePromise, 2_000));
}
console.log(`review screenshot still processing: ${resource.id}`);
