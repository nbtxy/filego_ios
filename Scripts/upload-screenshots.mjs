#!/usr/bin/env node
/**
 * Replace an App Store screenshot set through the App Store Connect API.
 *
 * Fastlane 2.237 predates the Duo display type and its overwrite path is
 * coarse, so this talks to the API directly. It works for both the regular
 * 6.9-inch set and the iPhone Duo set:
 *
 *   node Scripts/upload-screenshots.mjs --display-type APP_IPHONE_67 \
 *     --root fastlane/screenshots --replace
 *   node Scripts/upload-screenshots.mjs --display-type APP_IPHONE_DUO \
 *     --root fastlane/screenshots-duo --replace
 *
 * Requires ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_FILEPATH.
 */
import { createHash, createPrivateKey, createSign } from "node:crypto";
import { readFileSync, readdirSync } from "node:fs";
import { join, resolve } from "node:path";

const argv = process.argv.slice(2);
const APPLY_REPLACE = argv.includes("--replace");
function option(name, fallback) {
  const index = argv.indexOf(name);
  return index >= 0 && argv[index + 1] ? argv[index + 1] : fallback;
}
const APP_ID = "6798472788";
const VERSION = process.env.APP_VERSION ?? "1.0.7";
const DISPLAY_TYPE = option("--display-type", "APP_IPHONE_67");
const ROOT = resolve(option("--root", "fastlane/screenshots"));
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
  if (!keyId || !issuer || !path) {
    throw new Error("缺少 ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_FILEPATH");
  }
  const now = Math.floor(Date.now() / 1000);
  const header = b64url(JSON.stringify({ alg: "ES256", kid: keyId, typ: "JWT" }));
  const payload = b64url(JSON.stringify({
    iss: issuer, iat: now, exp: now + 600, aud: "appstoreconnect-v1",
  }));
  const signer = createSign("SHA256");
  signer.update(`${header}.${payload}`);
  const signature = signer.sign(createPrivateKey(readFileSync(path, "utf8")));
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

function imagePaths(locale) {
  return readdirSync(join(ROOT, locale))
    .filter((name) => /^\d+\.png$/.test(name))
    .sort()
    .map((name) => join(ROOT, locale, name));
}

async function waitForAsset(id) {
  for (let attempt = 0; attempt < 40; attempt += 1) {
    const current = await asc("GET", `/v1/appScreenshots/${id}`);
    const state = current.data.attributes.assetDeliveryState?.state;
    if (state === "COMPLETE") return;
    if (state === "FAILED") {
      throw new Error(`截图处理失败：${JSON.stringify(current.data.attributes, null, 2)}`);
    }
    await new Promise((resolvePromise) => setTimeout(resolvePromise, 2_000));
  }
  console.log(`  still processing: ${id}`);
}

async function uploadOne(setId, path) {
  const image = readFileSync(path);
  const checksum = createHash("md5").update(image).digest("hex");
  const reservation = await asc("POST", "/v1/appScreenshots", {
    data: {
      type: "appScreenshots",
      attributes: { fileSize: image.length, fileName: path.split("/").pop() },
      relationships: {
        appScreenshotSet: { data: { type: "appScreenshotSets", id: setId } },
      },
    },
  });
  const resource = reservation.data;
  for (const operation of resource.attributes.uploadOperations ?? []) {
    const headers = Object.fromEntries(
      operation.requestHeaders.map((header) => [header.name, header.value]),
    );
    const response = await fetch(operation.url, {
      method: operation.method,
      headers,
      body: image.subarray(operation.offset, operation.offset + operation.length),
    });
    if (!response.ok) {
      throw new Error(`上传分片失败：${response.status} ${await response.text()}`);
    }
  }
  await asc("PATCH", `/v1/appScreenshots/${resource.id}`, {
    data: {
      type: "appScreenshots",
      id: resource.id,
      attributes: { uploaded: true, sourceFileChecksum: checksum },
    },
  });
  await waitForAsset(resource.id);
}

async function main() {
  const versions = await asc(
    "GET",
    `/v1/apps/${APP_ID}/appStoreVersions?filter[platform]=IOS&filter[versionString]=${VERSION}&limit=10`,
  );
  const version = versions.data[0];
  if (!version) throw new Error(`找不到 iOS ${VERSION} 版本`);
  console.log(`version: ${VERSION} (${version.attributes.appStoreState})`);

  const localizations = await asc(
    "GET",
    `/v1/appStoreVersions/${version.id}/appStoreVersionLocalizations?limit=200`,
  );
  for (const locale of LOCALES) {
    const localization = localizations.data.find((item) => item.attributes.locale === locale);
    if (!localization) throw new Error(`找不到 ${locale} 的版本本地化`);
    const sets = await asc(
      "GET",
      `/v1/appStoreVersionLocalizations/${localization.id}/appScreenshotSets?limit=50`,
    );
    let set = sets.data.find((item) => item.attributes.screenshotDisplayType === DISPLAY_TYPE);
    if (!set) {
      set = (await asc("POST", "/v1/appScreenshotSets", {
        data: {
          type: "appScreenshotSets",
          attributes: { screenshotDisplayType: DISPLAY_TYPE },
          relationships: {
            appStoreVersionLocalization: {
              data: { type: "appStoreVersionLocalizations", id: localization.id },
            },
          },
        },
      })).data;
      console.log(`${locale}: created ${DISPLAY_TYPE} set ${set.id}`);
    } else {
      console.log(`${locale}: existing ${DISPLAY_TYPE} set ${set.id}`);
      const shots = await asc("GET", `/v1/appScreenshotSets/${set.id}/appScreenshots?limit=50`);
      if (shots.data.length > 0) {
        if (!APPLY_REPLACE) {
          console.log(`${locale}: already has ${shots.data.length} screenshots, skipping (use --replace)`);
          continue;
        }
        for (const shot of shots.data) {
          await asc("DELETE", `/v1/appScreenshots/${shot.id}`);
        }
        console.log(`${locale}: deleted ${shots.data.length} existing screenshots`);
      }
    }

    for (const path of imagePaths(locale)) {
      await uploadOne(set.id, path);
      console.log(`  uploaded ${path}`);
    }
  }
  console.log("done");
}

main().catch((error) => {
  console.error(error.message);
  process.exit(1);
});
