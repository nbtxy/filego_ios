#!/usr/bin/env node
import { createPrivateKey, createSign } from "node:crypto";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const APP_ID = "6798472788";
const VERSION = "1.0";
const APPLY_REVIEW = process.argv.includes("--apply-review");
const METADATA_ROOT = new URL("../fastlane/metadata/", import.meta.url).pathname;
const LOCALES = ["en-US", "zh-Hans", "zh-Hant"];

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
    iss: issuer, iat: now, exp: now + 600, aud: "appstoreconnect-v1",
  }));
  const signer = createSign("SHA256");
  signer.update(`${header}.${payload}`);
  const signature = signer.sign(createPrivateKey(readFileSync(keyPath, "utf8")));
  return `${header}.${payload}.${b64url(derToP1363(signature))}`;
}

async function asc(path, { method = "GET", body } = {}) {
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
    throw new Error(`GET ${path} -> ${response.status}\n${JSON.stringify(parsed?.errors ?? parsed, null, 2)}`);
  }
  return parsed;
}

function local(locale, filename) {
  return readFileSync(join(METADATA_ROOT, locale, filename), "utf8").trim();
}

function report(scope, locale, field, expected, actual) {
  const matches = expected === (actual ?? "").trim();
  console.log(`${matches ? "OK" : "DIFF"} ${scope}/${locale}/${field}`);
  if (!matches) {
    console.log(`  local : ${JSON.stringify(expected)}`);
    console.log(`  remote: ${JSON.stringify(actual ?? "")}`);
  }
  return matches;
}

const versions = await asc(
  `/v1/apps/${APP_ID}/appStoreVersions?filter[platform]=IOS&filter[versionString]=${VERSION}&limit=10`,
);
const version = versions.data[0];
if (!version) throw new Error(`找不到 iOS ${VERSION} 版本`);
console.log(`version: ${version.attributes.versionString} (${version.attributes.appStoreState})`);

const versionLocalizations = await asc(
  `/v1/appStoreVersions/${version.id}/appStoreVersionLocalizations?limit=200`,
);
const versionByLocale = new Map(versionLocalizations.data.map((item) => [item.attributes.locale, item]));

const appInfos = await asc(`/v1/apps/${APP_ID}/appInfos?limit=20`);
const appInfo = appInfos.data.find((item) => item.attributes.appStoreState !== "READY_FOR_SALE")
  ?? appInfos.data[0];
if (!appInfo) throw new Error("找不到 App Info");
const infoLocalizations = await asc(`/v1/appInfos/${appInfo.id}/appInfoLocalizations?limit=200`);
const infoByLocale = new Map(infoLocalizations.data.map((item) => [item.attributes.locale, item]));

let clean = true;
for (const locale of LOCALES) {
  const versionAttributes = versionByLocale.get(locale)?.attributes ?? {};
  const infoAttributes = infoByLocale.get(locale)?.attributes ?? {};
  clean = report("version", locale, "description", local(locale, "description.txt"), versionAttributes.description) && clean;
  clean = report("version", locale, "keywords", local(locale, "keywords.txt"), versionAttributes.keywords) && clean;
  clean = report("version", locale, "promotionalText", local(locale, "promotional_text.txt"), versionAttributes.promotionalText) && clean;
  if (versionAttributes.whatsNew) {
    clean = report("version", locale, "whatsNew", local(locale, "release_notes.txt"), versionAttributes.whatsNew) && clean;
  } else {
    console.log(`OK version/${locale}/whatsNew（首个版本不接受更新说明）`);
  }
  clean = report("version", locale, "supportUrl", local(locale, "support_url.txt"), versionAttributes.supportUrl) && clean;
  clean = report("info", locale, "name", local(locale, "name.txt"), infoAttributes.name) && clean;
  clean = report("info", locale, "subtitle", local(locale, "subtitle.txt"), infoAttributes.subtitle) && clean;
  clean = report("info", locale, "privacyPolicyUrl", local(locale, "privacy_url.txt"), infoAttributes.privacyPolicyUrl) && clean;
}

const reviewDetails = await asc(`/v1/appStoreVersions/${version.id}/appStoreReviewDetail`);
const reviewNote = readFileSync(join(METADATA_ROOT, "review_information", "notes.txt"), "utf8").trim();
const reviewMatches = report(
  "review", "shared", "notes", reviewNote, reviewDetails.data?.attributes?.notes,
);
if (!reviewMatches && APPLY_REVIEW) {
  const current = reviewDetails.data.attributes;
  const reviewContact = {
    contactFirstName: current.contactFirstName || process.env.ASC_REVIEW_FIRST_NAME,
    contactLastName: current.contactLastName || process.env.ASC_REVIEW_LAST_NAME,
    contactEmail: current.contactEmail || process.env.ASC_REVIEW_EMAIL,
    contactPhone: current.contactPhone || process.env.ASC_REVIEW_PHONE,
  };
  const missingContact = Object.entries(reviewContact)
    .filter(([, value]) => !value)
    .map(([key]) => key);
  if (missingContact.length) {
    throw new Error(
      `审核备注需要先补齐联系人字段：${missingContact.join(", ")}。` +
      "请设置 ASC_REVIEW_FIRST_NAME / ASC_REVIEW_LAST_NAME / " +
      "ASC_REVIEW_EMAIL / ASC_REVIEW_PHONE（电话须含 +国家码）。",
    );
  }
  const attributes = {
    ...reviewContact,
    ...Object.fromEntries(
      ["demoAccountName", "demoAccountPassword", "demoAccountRequired"]
        .filter((key) => current[key] !== undefined)
        .map((key) => [key, current[key]]),
    ),
  };
  attributes.notes = reviewNote;
  await asc(`/v1/appStoreReviewDetails/${reviewDetails.data.id}`, {
    method: "PATCH",
    body: {
      data: { type: "appStoreReviewDetails", id: reviewDetails.data.id, attributes },
    },
  });
  const verifiedReview = await asc(`/v1/appStoreVersions/${version.id}/appStoreReviewDetail`);
  const verified = verifiedReview.data?.attributes?.notes?.trim() === reviewNote;
  console.log(verified
    ? "review/shared/notes: 已更新并回读确认（联系人字段保持不变）"
    : "review/shared/notes: 更新后回读不一致");
  clean = verified && clean;
} else {
  clean = reviewMatches && clean;
}

console.log(clean ? "metadata: 已与仓库一致" : "metadata: 需要同步");
process.exitCode = clean ? 0 : 2;
