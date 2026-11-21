#!/usr/bin/env node
/** 同步已存在的 Stolnk 会员年度订阅文案与 US$1.99 基准价格；重复运行幂等。 */
import { readFileSync } from "node:fs";
import { createSign, createPrivateKey } from "node:crypto";

const APPLY = process.argv.includes("--apply");
const APP_ID = "6798472788";                            // com.nbtxy.filego
const PRODUCT_ID = "com.nbtxy.filego.member.yearly";
const GROUP_REFERENCE_NAME = "Stolnk Membership";
const SUBSCRIPTION_REFERENCE_NAME = "Stolnk Membership Yearly";
const BASE_TERRITORY = "USA";
const TARGET_PRICE = "1.99";
const REVIEW_NOTE =
  "Auto-renewable yearly membership: download links for files, a permanent " +
  "subdomain (otherwise expires 7 days after registration), " +
  "20 GB files, 300 GB/month relay, and password-protected links. " +
  "Paywall: Me tab -> Membership, or Create download link.";

// 订阅 id / 组 id 不写死：商品是后建的，按 productId 现查，脚本可重复运行。
let GROUP_ID;
let SUBSCRIPTION_ID;

function requiredFor(GROUP_ID, SUBSCRIPTION_ID) {
  return [
  {
    endpoint: `/v1/subscriptionGroups/${GROUP_ID}/subscriptionGroupLocalizations?limit=200`,
    postEndpoint: "/v1/subscriptionGroupLocalizations",
    type: "subscriptionGroupLocalizations",
    relationship: "subscriptionGroup",
    relationshipType: "subscriptionGroups",
    relationshipId: GROUP_ID,
    attributes: { locale: "zh-Hans", name: "Stolnk 会员" },
  },
  {
    endpoint: `/v1/subscriptionGroups/${GROUP_ID}/subscriptionGroupLocalizations?limit=200`,
    postEndpoint: "/v1/subscriptionGroupLocalizations",
    type: "subscriptionGroupLocalizations",
    relationship: "subscriptionGroup",
    relationshipType: "subscriptionGroups",
    relationshipId: GROUP_ID,
    attributes: { locale: "zh-Hant", name: "Stolnk 會員" },
  },
  {
    endpoint: `/v1/subscriptionGroups/${GROUP_ID}/subscriptionGroupLocalizations?limit=200`,
    postEndpoint: "/v1/subscriptionGroupLocalizations",
    type: "subscriptionGroupLocalizations",
    relationship: "subscriptionGroup",
    relationshipType: "subscriptionGroups",
    relationshipId: GROUP_ID,
    attributes: { locale: "en-US", name: "Stolnk Membership" },
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
      name: "Stolnk 会员",
      description: "下载链接与永久子域名，每年 $1.99",
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
      name: "Stolnk 會員",
      description: "下載連結與永久子網域，每年 $1.99",
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
      name: "Stolnk Membership",
      description: "Download links and a permanent subdomain.",
    },
  },
  ];
}

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

if (!APPLY) console.log("== dry-run（只读查询，不写 ASC）==");
const groups = await asc("GET", `/v1/apps/${APP_ID}/subscriptionGroups?limit=200`);
for (const group of groups.data) {
  const subscriptions = await asc(
    "GET", `/v1/subscriptionGroups/${group.id}/subscriptions?limit=200`);
  const match = subscriptions.data.find(
    (subscription) => subscription.attributes.productId === PRODUCT_ID);
  if (match) {
    GROUP_ID = group.id;
    SUBSCRIPTION_ID = match.id;
    break;
  }
}
if (!SUBSCRIPTION_ID) {
  throw new Error(
    `ASC 里还没有 ${PRODUCT_ID}。先运行 Scripts/create-subscription.mjs --apply 创建。`);
}
console.log(`订阅组 ${GROUP_ID} / 商品 ${SUBSCRIPTION_ID}（${PRODUCT_ID}）`);
const REQUIRED = requiredFor(GROUP_ID, SUBSCRIPTION_ID);

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

const group = await asc("GET", `/v1/subscriptionGroups/${GROUP_ID}`);
if (group.data.attributes.referenceName !== GROUP_REFERENCE_NAME) {
  await mutate("PATCH", `/v1/subscriptionGroups/${GROUP_ID}`, {
    data: {
      type: "subscriptionGroups",
      id: GROUP_ID,
      attributes: { referenceName: GROUP_REFERENCE_NAME },
    },
  });
  console.log(`subscriptionGroup referenceName: ${APPLY ? "已更新" : "需要更新"}`);
} else {
  console.log("subscriptionGroup referenceName: 已是最新");
}

const subscription = await asc("GET", `/v1/subscriptions/${SUBSCRIPTION_ID}`);
if (subscription.data.attributes.name !== SUBSCRIPTION_REFERENCE_NAME) {
  await mutate("PATCH", `/v1/subscriptions/${SUBSCRIPTION_ID}`, {
    data: {
      type: "subscriptions",
      id: SUBSCRIPTION_ID,
      attributes: { name: SUBSCRIPTION_REFERENCE_NAME },
    },
  });
  console.log(`subscription referenceName: ${APPLY ? "已更新" : "需要更新"}`);
} else {
  console.log("subscription referenceName: 已是最新");
}
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

// Apple 的 subscriptionPrices 每次只改【一个地区】。先找美区 $1.99 价格点，再取
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
  `目标价格: 美区 $${basePoint.attributes.customerPrice}/年；` +
    `中国区 ¥${chinaPoint?.attributes.customerPrice ?? "—"}/年；共 ${desiredByTerritory.size} 个地区`,
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
