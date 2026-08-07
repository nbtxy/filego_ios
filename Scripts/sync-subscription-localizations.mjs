#!/usr/bin/env node
/** 补齐已存在的 FileGo Pro 订阅本地化；重复运行不会创建重复项。 */
import { readFileSync } from "node:fs";
import { createSign, createPrivateKey } from "node:crypto";

const APPLY = process.argv.includes("--apply");
const GROUP_ID = "22290281";
const SUBSCRIPTION_ID = "6798478945";

const REQUIRED = [
  {
    endpoint: `/v1/subscriptionGroups/${GROUP_ID}/subscriptionGroupLocalizations?limit=200`,
    postEndpoint: "/v1/subscriptionGroupLocalizations",
    type: "subscriptionGroupLocalizations",
    relationship: "subscriptionGroup",
    relationshipType: "subscriptionGroups",
    relationshipId: GROUP_ID,
    attributes: { locale: "zh-Hant", name: "FileGo 會員" },
  },
  {
    endpoint: `/v1/subscriptions/${SUBSCRIPTION_ID}/subscriptionLocalizations?limit=200`,
    postEndpoint: "/v1/subscriptionLocalizations",
    type: "subscriptionLocalizations",
    relationship: "subscription",
    relationshipType: "subscriptions",
    relationshipId: SUBSCRIPTION_ID,
    attributes: {
      locale: "zh-Hant",
      name: "Pro 會員",
      description: "10 GB 雲端空間，照片影片隨手存。",
    },
  },
];

function b64url(value) {
  return Buffer.from(value).toString("base64url");
}

function derToP1363(der) {
  let offset = 2;
  if (der[1] & 0x80) offset = 2 + (der[1] & 0x7f);
  const rLength = der[offset + 1];
  const r = der.subarray(offset + 2, offset + 2 + rLength);
  const sOffset = offset + 2 + rLength;
  const sLength = der[sOffset + 1];
  const s = der.subarray(sOffset + 2, sOffset + 2 + sLength);
  const pad = (part) => {
    const output = Buffer.alloc(32);
    const trimmed = part[0] === 0 ? part.subarray(1) : part;
    trimmed.copy(output, 32 - trimmed.length);
    return output;
  };
  return Buffer.concat([pad(r), pad(s)]);
}

function token() {
  const keyId = process.env.ASC_KEY_ID;
  const issuer = process.env.ASC_ISSUER_ID;
  const keyPath = process.env.ASC_KEY_FILEPATH;
  if (!keyId || !issuer || !keyPath) {
    throw new Error("缺少 ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_FILEPATH");
  }
  const now = Math.floor(Date.now() / 1000);
  const header = b64url(JSON.stringify({ alg: "ES256", kid: keyId, typ: "JWT" }));
  const payload = b64url(JSON.stringify({
    iss: issuer,
    iat: now,
    exp: now + 600,
    aud: "appstoreconnect-v1",
  }));
  const signer = createSign("SHA256");
  signer.update(`${header}.${payload}`);
  const signature = signer.sign(createPrivateKey(readFileSync(keyPath, "utf8")));
  return `${header}.${payload}.${b64url(derToP1363(signature))}`;
}

async function asc(method, path, body) {
  const response = await fetch(`https://api.appstoreconnect.apple.com${path}`, {
    method,
    headers: {
      Authorization: `Bearer ${token()}`,
      ...(body ? { "Content-Type": "application/json" } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  const parsed = await response.json().catch(() => null);
  if (!response.ok) {
    throw new Error(`${method} ${path} -> ${response.status}\n${JSON.stringify(parsed?.errors ?? parsed, null, 2)}`);
  }
  return parsed;
}

for (const item of REQUIRED) {
  const existing = await asc("GET", item.endpoint);
  const match = existing.data.find((entry) => entry.attributes.locale === item.attributes.locale);
  if (match) {
    console.log(`${item.type} ${item.attributes.locale}: 已存在`);
    continue;
  }
  if (!APPLY) {
    console.log(`${item.type} ${item.attributes.locale}: 缺少（dry-run）`);
    continue;
  }
  await asc("POST", item.postEndpoint, {
    data: {
      type: item.type,
      attributes: item.attributes,
      relationships: {
        [item.relationship]: {
          data: { type: item.relationshipType, id: item.relationshipId },
        },
      },
    },
  });
  console.log(`${item.type} ${item.attributes.locale}: 已创建`);
}
