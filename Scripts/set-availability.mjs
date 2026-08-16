#!/usr/bin/env node
/**
 * Configure JustFling for every App Store territory except China mainland.
 *
 * Required environment variables:
 *   ASC_KEY_ID  ASC_ISSUER_ID  ASC_KEY_FILEPATH
 *
 * Usage:
 *   node Scripts/set-availability.mjs          # read current state and print the request
 *   node Scripts/set-availability.mjs --apply  # send the request when a change is needed
 */
import { createPrivateKey, createSign } from "node:crypto";
import { readFileSync } from "node:fs";

const APPLY = process.argv.includes("--apply");
const APP_ID = "6798472788";
const EXCLUDED = new Set(["CHN"]);

function b64url(value) {
  return Buffer.from(value).toString("base64")
    .replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function derToP1363(der) {
  let offset = 2;
  if (der[1] & 0x80) offset = 2 + (der[1] & 0x7f);
  const rLength = der[offset + 1];
  const r = der.subarray(offset + 2, offset + 2 + rLength);
  const sOffset = offset + 2 + rLength;
  const sLength = der[sOffset + 1];
  const s = der.subarray(sOffset + 2, sOffset + 2 + sLength);
  const fixed = (bytes) => {
    const result = Buffer.alloc(32);
    const trimmed = bytes[0] === 0 ? bytes.subarray(1) : bytes;
    trimmed.copy(result, 32 - trimmed.length);
    return result;
  };
  return Buffer.concat([fixed(r), fixed(s)]);
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

async function asc(method, path, body, { allowNotFound = false } = {}) {
  const response = await fetch(`https://api.appstoreconnect.apple.com${path}`, {
    method,
    headers: {
      Authorization: `Bearer ${token()}`,
      ...(body ? { "Content-Type": "application/json" } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  const parsed = await response.json().catch(() => null);
  if (allowNotFound && response.status === 404) return null;
  if (!response.ok) {
    throw new Error(
      `${method} ${path} -> ${response.status}\n${JSON.stringify(parsed?.errors ?? parsed, null, 2)}`,
    );
  }
  return parsed;
}

async function currentAvailability() {
  const response = await asc(
    "GET",
    `/v1/apps/${APP_ID}/appAvailabilityV2?fields[appAvailabilities]=availableInNewTerritories`,
    undefined,
    { allowNotFound: true },
  );
  if (!response) return null;
  const id = response.data?.id;
  if (!id) return null;
  const territories = await asc(
    "GET",
    `/v2/appAvailabilities/${id}/territoryAvailabilities?include=territory&limit=200`,
  );
  const territoryByResource = new Map(
    (territories.included ?? [])
      .filter((item) => item.type === "territories")
      .map((item) => [item.id, item.id]),
  );
  const available = new Set();
  for (const item of territories.data ?? []) {
    if (item.attributes?.available !== true) continue;
    const territoryId = item.relationships?.territory?.data?.id;
    if (territoryId && territoryByResource.has(territoryId)) available.add(territoryId);
  }
  return {
    id,
    available,
    availableInNewTerritories: response.data.attributes?.availableInNewTerritories === true,
  };
}

function createBody(territoryIds) {
  const included = territoryIds.map((territory) => {
    // ASC 的 inline-create 临时 id 必须保留 ${...} 包裹格式。
    // 后缀必须是实际地区代码；用顺序号会被解析成错误的 territory 关系。
    const lid = `\${territory-${territory}}`;
    return {
      type: "territoryAvailabilities",
      id: lid,
      // Create requires a row for every current territory. Exclusions are
      // represented explicitly as unavailable rather than omitted.
      attributes: { available: !EXCLUDED.has(territory) },
      relationships: { territory: { data: { type: "territories", id: territory } } },
    };
  });
  return {
    data: {
      type: "appAvailabilities",
      attributes: { availableInNewTerritories: false },
      relationships: {
        app: { data: { type: "apps", id: APP_ID } },
        territoryAvailabilities: {
          // 这里的 id 是本次请求内的临时关联值，不是服务端资源 id。
          data: included.map(({ type, id }) => ({ type, id })),
        },
      },
    },
    included,
  };
}

function setsEqual(left, right) {
  return left.size === right.size && [...left].every((value) => right.has(value));
}

async function main() {
  const territories = await asc("GET", "/v1/territories?limit=200");
  const allTerritoryIds = (territories.data ?? []).map((item) => item.id).sort();
  const targetIds = allTerritoryIds.filter((id) => !EXCLUDED.has(id));
  if (targetIds.length === 0 || targetIds.includes("CHN")) {
    throw new Error("地区列表异常，拒绝生成上架请求");
  }

  const current = await currentAvailability();
  const target = new Set(targetIds);
  if (current && !current.availableInNewTerritories && setsEqual(current.available, target)) {
    console.log(`已是目标状态：${target.size} 个地区，排除 CHN，未来新地区不自动上架。`);
    return;
  }

  const body = createBody(allTerritoryIds);
  console.log(`目标：${targetIds.length} 个地区；排除：${[...EXCLUDED].join(", ")}`);
  console.log(JSON.stringify(body, null, 2));
  if (!APPLY) {
    console.log("\ndry-run：未修改 App Store Connect。确认后添加 --apply。 ");
    return;
  }

  await asc("POST", "/v2/appAvailabilities", body);
  const verified = await currentAvailability();
  if (!verified || verified.availableInNewTerritories || !setsEqual(verified.available, target)) {
    throw new Error("请求已发送，但回读状态与目标不一致；请到 App Store Connect 网页核对。");
  }
  console.log(`已应用并回读确认：${verified.available.size} 个地区，CHN 未上架。`);
}

main().catch((error) => {
  console.error(`\n失败：${error.message}`);
  process.exitCode = 1;
});
