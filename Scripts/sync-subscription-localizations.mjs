#!/usr/bin/env node
/** 同步已存在的 FileGo Pro 订阅文案与 US$2.99 基准价格；重复运行幂等。 */
import { readFileSync } from "node:fs";
import { createSign, createPrivateKey } from "node:crypto";

const APPLY = process.argv.includes("--apply");
const GROUP_ID = "22290281";
const SUBSCRIPTION_ID = "6798478945";
const BASE_TERRITORY = "USA";
const TARGET_PRICE = "2.99";
const REVIEW_NOTE =
  "Auto-renewable subscription: 50 GB storage, unlimited import addresses, " +
  "1/7/30/90-day or non-expiring addresses, and direct uploads up to 5 GB per file. " +
  "Paywall: Me tab -> Upgrade to Pro.";

const REQUIRED = [
  {
    endpoint: `/v1/subscriptionGroups/${GROUP_ID}/subscriptionGroupLocalizations?limit=200`,
    postEndpoint: "/v1/subscriptionGroupLocalizations",
    type: "subscriptionGroupLocalizations",
    relationship: "subscriptionGroup",
    relationshipType: "subscriptionGroups",
    relationshipId: GROUP_ID,
    attributes: { locale: "zh-Hans", name: "FileGo 会员" },
  },
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
    endpoint: `/v1/subscriptionGroups/${GROUP_ID}/subscriptionGroupLocalizations?limit=200`,
    postEndpoint: "/v1/subscriptionGroupLocalizations",
    type: "subscriptionGroupLocalizations",
    relationship: "subscriptionGroup",
    relationshipType: "subscriptionGroups",
    relationshipId: GROUP_ID,
    attributes: { locale: "en-US", name: "FileGo Membership" },
  },
  {
    endpoint: `/v1/subscriptions/${SUBSCRIPTION_ID}/subscriptionLocalizations?limit=200`,
    postEndpoint: "/v1/subscriptionLocalizations",
    type: "subscriptionLocalizations",
    relationship: "subscription",
    relationshipType: "subscriptions",
    relationshipId: SUBSCRIPTION_ID,
    attributes: {
      locale: "zh-Hans",
      name: "Pro 会员",
      description: "50 GB、导入地址不限量、永久有效、单文件 5 GB 直传",
    },
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
      description: "50 GB、匯入地址不限量、永久有效、單檔 5 GB 直傳",
    },
  },
  {
    endpoint: `/v1/subscriptions/${SUBSCRIPTION_ID}/subscriptionLocalizations?limit=200`,
    postEndpoint: "/v1/subscriptionLocalizations",
    type: "subscriptionLocalizations",
    relationship: "subscription",
    relationshipType: "subscriptions",
    relationshipId: SUBSCRIPTION_ID,
    attributes: {
      locale: "en-US",
      name: "FileGo Pro",
      description: "50 GB, unlimited links, 5 GB direct uploads.",
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

async function mutate(method, path, body) {
  if (!APPLY) {
    console.log(`${method} ${path}（dry-run）`);
    return null;
  }
  return asc(method, path, body);
}

for (const item of REQUIRED) {
  const existing = await asc("GET", item.endpoint);
  const match = existing.data.find((entry) => entry.attributes.locale === item.attributes.locale);
  if (match) {
    const changed = Object.entries(item.attributes)
      .some(([key, value]) => match.attributes[key] !== value);
    if (!changed) {
      console.log(`${item.type} ${item.attributes.locale}: 已是最新`);
      continue;
    }
    // locale 是创建后不可变属性；ASC 的 PATCH 只接受可编辑的 name / description。
    const { locale: _, ...updateAttributes } = item.attributes;
    await mutate("PATCH", `/v1/${item.type}/${match.id}`, {
      data: { type: item.type, id: match.id, attributes: updateAttributes },
    });
    console.log(`${item.type} ${item.attributes.locale}: ${APPLY ? "已更新" : "需要更新"}`);
    continue;
  }
  await mutate("POST", item.postEndpoint, {
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
  console.log(`${item.type} ${item.attributes.locale}: ${APPLY ? "已创建" : "缺少"}`);
}

const subscription = await asc("GET", `/v1/subscriptions/${SUBSCRIPTION_ID}`);
if (subscription.data.attributes.reviewNote !== REVIEW_NOTE) {
  await mutate("PATCH", `/v1/subscriptions/${SUBSCRIPTION_ID}`, {
    data: {
      type: "subscriptions",
      id: SUBSCRIPTION_ID,
      attributes: { reviewNote: REVIEW_NOTE },
    },
  });
  console.log(`reviewNote: ${APPLY ? "已更新" : "需要更新"}`);
} else {
  console.log("reviewNote: 已是最新");
}

// Apple 的 subscriptionPrices 每次只改【一个地区】。先找美区 $2.99 价格点，再取
// adjustedEqualizations，把 Apple 按当地定价规则推荐的等值价格逐区写入。只 POST
// 美区价格点不会自动传播到其它地区（这正是旧脚本曾漏掉的地方）。
const basePoints = await asc(
  "GET",
  `/v1/subscriptions/${SUBSCRIPTION_ID}/pricePoints?filter[territory]=${BASE_TERRITORY}&limit=200`,
);
const basePoint = basePoints.data.find((point) => point.attributes.customerPrice === TARGET_PRICE);
if (!basePoint) throw new Error(`美区没有 $${TARGET_PRICE} 价格点`);

const equalizations = await asc(
  "GET",
  `/v1/subscriptionPricePoints/${basePoint.id}/equalizations?include=territory&limit=8000`,
);
const desiredPoints = [basePoint, ...equalizations.data];
function territoryForPricePoint(point) {
  const related = point.relationships?.territory?.data?.id;
  if (related) return related;
  // ASC 的 opaque id 目前是 base64url(JSON)，equalizations 偶尔省略 territory
  // relationship；只把解码作为响应兼容兜底，并校验结果形状。
  const decoded = JSON.parse(Buffer.from(point.id, "base64url").toString("utf8"));
  if (typeof decoded.t !== "string") throw new Error(`价格点缺少地区: ${point.id}`);
  return decoded.t;
}
const desiredByTerritory = new Map(desiredPoints.map((point) => [
  territoryForPricePoint(point),
  point,
]));

const configured = await asc(
  "GET",
  `/v1/subscriptions/${SUBSCRIPTION_ID}/prices?include=territory,subscriptionPricePoint&limit=200`,
);
const configuredPointIdsByTerritory = new Map();
for (const price of configured.data) {
  const territory = price.relationships.territory.data.id;
  const pointId = price.relationships.subscriptionPricePoint.data.id;
  const ids = configuredPointIdsByTerritory.get(territory) ?? new Set();
  ids.add(pointId);
  configuredPointIdsByTerritory.set(territory, ids);
}

const missing = [...desiredByTerritory.entries()].filter(([territory, point]) =>
  !configuredPointIdsByTerritory.get(territory)?.has(point.id)
);
const chinaPoint = desiredByTerritory.get("CHN");
console.log(
  `目标价格: 美区 $${basePoint.attributes.customerPrice}/月；` +
    `中国区 ¥${chinaPoint?.attributes.customerPrice ?? "—"}/月；共 ${desiredByTerritory.size} 个地区`,
);
console.log(`仍需同步: ${missing.length} 个地区`);

if (APPLY && missing.length) {
  const setPrice = async ([, point]) => asc("POST", "/v1/subscriptionPrices", {
    data: {
      type: "subscriptionPrices",
      attributes: { preserveCurrentPrice: false },
      relationships: {
        subscription: { data: { type: "subscriptions", id: SUBSCRIPTION_ID } },
        subscriptionPricePoint: {
          data: { type: "subscriptionPricePoints", id: point.id },
        },
      },
    },
  });
  // 小批量并发，既缩短 170+ 地区的同步时间，也避免撞 ASC 频率限制。
  for (let offset = 0; offset < missing.length; offset += 8) {
    await Promise.all(missing.slice(offset, offset + 8).map(setPrice));
    console.log(`价格同步进度: ${Math.min(offset + 8, missing.length)}/${missing.length}`);
  }
}
