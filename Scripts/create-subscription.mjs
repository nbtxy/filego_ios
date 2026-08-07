#!/usr/bin/env node
/**
 * 在 App Store Connect 建 FileGo Pro 月度订阅。
 *
 * 为什么不用 fastlane：fastlane 没有任何内购/订阅 action，spaceship 里唯一的
 * create_iap! 走的是已废弃的私有 iTunes Connect 接口（ra/apps/{id}/iaps/...），
 * 要 Apple ID + 密码 + 2FA，且对自动续期订阅支持不完整。官方 ASC API 从 2022 起
 * 补齐了 subscriptionGroups / subscriptions / subscriptionPrices 这组端点，
 * 用 Team Key（App Manager 角色）即可，这里直接调。
 *
 * 需要的环境变量（与 qingshu_ios/fastlane/Fastfile 同一套）：
 *   ASC_KEY_ID  ASC_ISSUER_ID  ASC_KEY_FILEPATH
 *
 * 用法：
 *   node Scripts/create-subscription.mjs            # dry-run，只打印将要发送的请求
 *   node Scripts/create-subscription.mjs --apply    # 真正创建
 *
 * ⚠️ productId 一旦创建就永久占用，ASC 里只能停售、不能删除、不可复用。
 */
import { readFileSync } from "node:fs";
import { createSign, createPrivateKey } from "node:crypto";

const APPLY = process.argv.includes("--apply");

const APP_ID = "6798472788";                            // com.nbtxy.filego
const PRODUCT_ID = "com.nbtxy.filego.pro.monthly";      // 与 filego/src/lib/plans.ts 的 PRO_PRODUCT_ID 一致
const BASE_TERRITORY = "USA";
const TARGET_PRICE = "0.49";

// 内部名（referenceName / name）不对用户可见，只在 ASC 后台和报表里出现。
const GROUP_REFERENCE_NAME = "FileGo Pro";
const SUBSCRIPTION_REFERENCE_NAME = "FileGo Pro Monthly";

// 用户可见：订阅组名出现在系统「管理订阅」页；商品名与描述出现在购买弹窗与订阅列表。
// Apple 限长：name ≤ 30 字符，description ≤ 45 字符。
const GROUP_LOCALIZATIONS = [
  { locale: "zh-Hans", name: "FileGo 会员" },
  { locale: "zh-Hant", name: "FileGo 會員" },
  { locale: "en-US",   name: "FileGo Membership" },
];
const SUBSCRIPTION_LOCALIZATIONS = [
  { locale: "zh-Hans", name: "Pro 会员",   description: "10 GB 云端空间，照片视频随手存。" },
  { locale: "zh-Hant", name: "Pro 會員",   description: "10 GB 雲端空間，照片影片隨手存。" },
  { locale: "en-US",   name: "FileGo Pro", description: "10 GB of space for photos and video." },
];

const REVIEW_NOTE =
  "Auto-renewable subscription that raises cloud storage from 20 MB to 10 GB. " +
  "Paywall: Me tab -> Upgrade to Pro.";

// ---------------------------------------------------------------------------

function b64url(buf) {
  return Buffer.from(buf).toString("base64")
    .replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** ASC 要 JWS 的 R||S 定长拼接，Node 的 sign() 给的是 DER，这里转一下。 */
function derToP1363(der) {
  let off = 2;
  if (der[1] & 0x80) off = 2 + (der[1] & 0x7f);
  const rLen = der[off + 1];
  const r = der.subarray(off + 2, off + 2 + rLen);
  const sOff = off + 2 + rLen;
  const sLen = der[sOff + 1];
  const s = der.subarray(sOff + 2, sOff + 2 + sLen);
  const pad = (b) => {
    const out = Buffer.alloc(32);
    const trimmed = b[0] === 0 ? b.subarray(1) : b;
    trimmed.copy(out, 32 - trimmed.length);
    return out;
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
    iss: issuer, iat: now, exp: now + 600, aud: "appstoreconnect-v1",
  }));
  const signer = createSign("SHA256");
  signer.update(`${header}.${payload}`);
  const der = signer.sign(createPrivateKey(readFileSync(keyPath, "utf8")));
  return `${header}.${payload}.${b64url(derToP1363(der))}`;
}

async function asc(method, path, body) {
  if (method !== "GET" && !APPLY) {
    console.log(`  [dry-run] ${method} ${path}`);
    console.log(`  ${JSON.stringify(body, null, 2).split("\n").join("\n  ")}`);
    return { data: { id: `<${method}-${path.split("/").pop()}-的返回 id>` } };
  }
  const res = await fetch(`https://api.appstoreconnect.apple.com${path}`, {
    method,
    headers: {
      Authorization: `Bearer ${token()}`,
      ...(body ? { "Content-Type": "application/json" } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  const parsed = await res.json().catch(() => null);
  if (!res.ok) {
    throw new Error(`${method} ${path} -> ${res.status}\n${JSON.stringify(parsed?.errors ?? parsed, null, 2)}`);
  }
  return parsed;
}

// ---------------------------------------------------------------------------

async function main() {
  console.log(APPLY ? "== 实际创建 ==" : "== dry-run（不会改动任何东西）==");

  // 1. 订阅组。同一组内的商品之间可以升降级；将来加年付就放进这个组。
  console.log("\n[1/5] 创建订阅组");
  const group = await asc("POST", "/v1/subscriptionGroups", {
    data: {
      type: "subscriptionGroups",
      attributes: { referenceName: GROUP_REFERENCE_NAME },
      relationships: { app: { data: { type: "apps", id: APP_ID } } },
    },
  });
  const groupId = group.data.id;
  console.log(`  组 id = ${groupId}`);

  // 2. 组的本地化名称（出现在系统「管理订阅」页）
  console.log("\n[2/5] 订阅组本地化");
  for (const loc of GROUP_LOCALIZATIONS) {
    await asc("POST", "/v1/subscriptionGroupLocalizations", {
      data: {
        type: "subscriptionGroupLocalizations",
        attributes: loc,
        relationships: {
          subscriptionGroup: { data: { type: "subscriptionGroups", id: groupId } },
        },
      },
    });
    console.log(`  ${loc.locale}: ${loc.name}`);
  }

  // 3. 商品本体。⚠️ productId 到这一步就被永久占用了。
  console.log("\n[3/5] 创建订阅商品");
  const sub = await asc("POST", "/v1/subscriptions", {
    data: {
      type: "subscriptions",
      attributes: {
        name: SUBSCRIPTION_REFERENCE_NAME,
        productId: PRODUCT_ID,
        subscriptionPeriod: "ONE_MONTH",
        familySharable: false,
        reviewNote: REVIEW_NOTE,
      },
      relationships: {
        group: { data: { type: "subscriptionGroups", id: groupId } },
      },
    },
  });
  const subId = sub.data.id;
  console.log(`  商品 id = ${subId}  productId = ${PRODUCT_ID}`);

  // 4. 商品本地化（购买弹窗里用户看到的名字与描述）
  console.log("\n[4/5] 商品本地化");
  for (const loc of SUBSCRIPTION_LOCALIZATIONS) {
    await asc("POST", "/v1/subscriptionLocalizations", {
      data: {
        type: "subscriptionLocalizations",
        attributes: loc,
        relationships: {
          subscription: { data: { type: "subscriptions", id: subId } },
        },
      },
    });
    console.log(`  ${loc.locale}: ${loc.name} — ${loc.description}`);
  }

  // 5. 销售地区。**必须先于定价**——没设地区就 POST /v1/subscriptionPrices，
  //    Apple 回 409 ENTITY_ERROR.RELATIONSHIP.INVALID 且 pointer 指向 pricePoint，
  //    错误信息完全指不到真正的原因（第一次实跑就是栽在这里）。
  console.log("\n[5/6] 设定销售地区");
  const territories = await asc("GET", "/v1/territories?limit=200");
  await asc("POST", "/v1/subscriptionAvailabilities", {
    data: {
      type: "subscriptionAvailabilities",
      // 以后 Apple 新开的地区自动上架，不用回来补
      attributes: { availableInNewTerritories: true },
      relationships: {
        subscription: { data: { type: "subscriptions", id: subId } },
        availableTerritories: {
          data: territories.data.map((t) => ({ type: "territories", id: t.id })),
        },
      },
    },
  });
  console.log(`  ${territories.data.length} 个地区，新开地区自动上架`);

  // 6. 价格。价格点只能在商品建好之后查，所以放最后。
  //    以美区为基准设价，ASC 会按汇率给其它地区生成对应价格（仍需人工过一遍）。
  console.log("\n[6/6] 设定价格");
  if (!APPLY) {
    console.log(`  [dry-run] 需要先建出商品才能查价格点，此步骤在 --apply 时执行`);
    console.log(`  将查 GET /v1/subscriptions/{id}/pricePoints?filter[territory]=${BASE_TERRITORY}`);
    console.log(`  然后挑 customerPrice == "${TARGET_PRICE}" 的那个价格点`);
  } else {
    // 注意 limit 上限是 50，超了会 400 PARAMETER_ERROR.INVALID。
    const points = await asc(
      "GET",
      `/v1/subscriptions/${subId}/pricePoints?filter[territory]=${BASE_TERRITORY}&limit=200`,
    );
    const match = points.data.find((p) => p.attributes.customerPrice === TARGET_PRICE);
    if (!match) {
      const near = points.data
        .map((p) => p.attributes.customerPrice)
        .filter((v) => parseFloat(v) < 1.5)
        .sort((a, b) => parseFloat(a) - parseFloat(b));
      throw new Error(
        `美区没有 $${TARGET_PRICE} 这个价格点。1.5 美元以下的可选值：${near.join(", ")}\n` +
        `商品已创建（id=${subId}），改上面的 TARGET_PRICE 后重跑第 5 步即可。`,
      );
    }
    await asc("POST", "/v1/subscriptionPrices", {
      data: {
        type: "subscriptionPrices",
        attributes: { preserveCurrentPrice: false },
        relationships: {
          subscription: { data: { type: "subscriptions", id: subId } },
          subscriptionPricePoint: {
            data: { type: "subscriptionPricePoints", id: match.id },
          },
        },
      },
    });
    console.log(`  美区 $${TARGET_PRICE}（价格点 ${match.id}），其它地区按汇率自动换算`);
  }

  console.log("\n完成。仍需手动：");
  console.log("  · 上传审核截图 —— 商品会停在 MISSING_METADATA 直到传了这张图。");
  console.log("    截图必须显示能正常加载出价格的付费墙，所以要先在 Xcode");
  console.log("    Scheme → Run → Options → StoreKit Configuration 选上");
  console.log("    filego/Resources/FileGo.storekit（simctl 的启动参数挂不上，试过了）。");
  console.log("  · 确认 Paid Applications Agreement 已生效，否则 Product.products(for:) 返回空数组");
  console.log("  · 人工过一遍各地区自动换算出来的价格");
}

main().catch((e) => { console.error("\n失败：", e.message); process.exit(1); });
