#!/usr/bin/env node
/** Create and configure Stolnk Pro as a $14.99 non-consumable IAP. */
import { createPrivateKey, createSign } from "node:crypto";
import { readFileSync } from "node:fs";

const APPLY = process.argv.includes("--apply");
const APP_ID = "6798472788";
const PRODUCT_ID = "com.nbtxy.filego.pro.lifetime";
const TARGET_PRICE = "14.99";
const BASE_TERRITORY = "USA";

const LOCALIZATIONS = [
  { locale: "en-US", name: "Stolnk Pro Lifetime", description: "Unlock every Stolnk Pro feature for good." },
  { locale: "zh-Hans", name: "Stolnk Pro 永久版", description: "永久解锁 Stolnk Pro 的全部功能" },
  { locale: "zh-Hant", name: "Stolnk Pro 永久版", description: "永久解鎖 Stolnk Pro 的全部功能" },
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
  if (!APPLY && method !== "GET") {
    console.log(`[dry-run] ${method} ${path}`);
    return { data: { id: `<${method}-${path.split("/").pop()}>` } };
  }
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

async function main() {
  const listed = await asc("GET", `/v1/apps/${APP_ID}/inAppPurchasesV2?filter[productId]=${PRODUCT_ID}&limit=10`);
  let purchase = listed.data[0];
  if (!purchase) {
    purchase = (await asc("POST", "/v2/inAppPurchases", {
      data: {
        type: "inAppPurchases",
        attributes: {
          name: "Stolnk Pro Lifetime",
          productId: PRODUCT_ID,
          inAppPurchaseType: "NON_CONSUMABLE",
          reviewNote: "One-time Pro unlock. Paywall: open the drawer, tap Plan, then tap Unlock forever.",
        },
        relationships: { app: { data: { type: "apps", id: APP_ID } } },
      },
    })).data;
    console.log(`created product ${purchase.id}`);
  } else {
    console.log(`product exists ${purchase.id} (${purchase.attributes.state})`);
  }
  if (!APPLY && String(purchase.id).startsWith("<")) return;

  const versions = await asc("GET", `/v2/inAppPurchases/${purchase.id}/versions?limit=50`);
  let version = versions.data.find((item) => item.attributes.state === "PREPARE_FOR_SUBMISSION") ?? versions.data[0];
  if (!version) {
    version = (await asc("POST", "/v1/inAppPurchaseVersions", {
      data: {
        type: "inAppPurchaseVersions",
        relationships: { inAppPurchase: { data: { type: "inAppPurchases", id: purchase.id } } },
      },
    })).data;
    console.log(`created metadata version ${version.id}`);
  }

  const existingLocalizations = await asc("GET", `/v1/inAppPurchaseVersions/${version.id}/localizations?limit=50`);
  for (const localization of LOCALIZATIONS) {
    if (existingLocalizations.data.some((item) => item.attributes.locale === localization.locale)) continue;
    await asc("POST", "/v2/inAppPurchaseLocalizations", {
      data: {
        type: "inAppPurchaseLocalizations",
        attributes: localization,
        relationships: { version: { data: { type: "inAppPurchaseVersions", id: version.id } } },
      },
    });
    console.log(`localized ${localization.locale}`);
  }

  const currentAvailability = await asc("GET", `/v2/inAppPurchases/${purchase.id}/inAppPurchaseAvailability`).catch((error) => {
    if (error.message.includes("-> 404")) return null;
    throw error;
  });
  if (!currentAvailability) {
    const territories = await asc("GET", "/v1/territories?limit=200");
    await asc("POST", "/v1/inAppPurchaseAvailabilities", {
      data: {
        type: "inAppPurchaseAvailabilities",
        attributes: { availableInNewTerritories: true },
        relationships: {
          availableTerritories: { data: territories.data.map((item) => ({ type: "territories", id: item.id })) },
          inAppPurchase: { data: { type: "inAppPurchases", id: purchase.id } },
        },
      },
    });
    console.log(`available in ${territories.data.length} territories`);
  }

  const currentSchedule = await asc("GET", `/v2/inAppPurchases/${purchase.id}/iapPriceSchedule`).catch((error) => {
    if (error.message.includes("-> 404")) return null;
    throw error;
  });
  const points = await asc("GET", `/v2/inAppPurchases/${purchase.id}/pricePoints?filter[territory]=${BASE_TERRITORY}&limit=8000`);
  const point = points.data.find((item) => item.attributes.customerPrice === TARGET_PRICE);
  if (!point) throw new Error(`找不到美区 $${TARGET_PRICE} 价格点`);
  let currentPrices = [];
  if (currentSchedule) {
    const prices = await asc(
      "GET",
      `/v1/inAppPurchasePriceSchedules/${currentSchedule.data.id}/manualPrices?filter[territory]=${BASE_TERRITORY}&include=inAppPurchasePricePoint&limit=50`,
    );
    currentPrices = prices.data;
  }
  const hasTargetPrice = currentPrices.some(
    (item) => item.relationships?.inAppPurchasePricePoint?.data?.id === point.id && item.attributes.startDate == null,
  );
  if (!hasTargetPrice) {
    const priceID = "${price1}";
    await asc("POST", "/v1/inAppPurchasePriceSchedules", {
      data: {
        type: "inAppPurchasePriceSchedules",
        relationships: {
          inAppPurchase: { data: { type: "inAppPurchases", id: purchase.id } },
          baseTerritory: { data: { type: "territories", id: BASE_TERRITORY } },
          manualPrices: { data: [{ type: "inAppPurchasePrices", id: priceID }] },
        },
      },
      included: [{
        type: "inAppPurchasePrices",
        id: priceID,
        attributes: { startDate: null },
        relationships: {
          inAppPurchaseV2: { data: { type: "inAppPurchases", id: purchase.id } },
          inAppPurchasePricePoint: { data: { type: "inAppPurchasePricePoints", id: point.id } },
        },
      }],
    });
    console.log(`priced at USA $${TARGET_PRICE}`);
  } else {
    console.log(`price already set at USA $${TARGET_PRICE}`);
  }

  const verified = await asc("GET", `/v2/inAppPurchases/${purchase.id}?include=inAppPurchaseAvailability,iapPriceSchedule`);
  console.log(JSON.stringify({
    id: verified.data.id,
    productId: verified.data.attributes.productId,
    type: verified.data.attributes.inAppPurchaseType,
    state: verified.data.attributes.state,
    metadataVersion: version.attributes.version,
  }, null, 2));
}

main().catch((error) => { console.error(error.message); process.exit(1); });
