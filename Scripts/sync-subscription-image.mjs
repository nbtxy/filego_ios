#!/usr/bin/env node
/** Replace the promoted JustFling Pro subscription image in App Store Connect. */
import { createHash, createPrivateKey, createSign } from "node:crypto";
import { readFileSync } from "node:fs";
import { basename, resolve } from "node:path";

const APPLY = process.argv.includes("--apply");
const AUDIT_SUBMISSION = process.argv.includes("--audit-submission");
const UNLOCK_SUBMISSION = process.argv.includes("--unlock-submission");
const RESOLVE_REJECTED_ITEM = process.argv.includes("--resolve-rejected-item");
const CANCEL_SUBMISSION = process.argv.includes("--cancel-submission");
const APP_ID = "6798472788";
const SUBSCRIPTION_GROUP_ID = "22290281";
const SUBSCRIPTION_ID = "6798478945";
const IMAGE_PATH = resolve("fastlane/promotional_images/justfling-pro-promotional.png");
const image = readFileSync(IMAGE_PATH);
const checksum = createHash("md5").update(image).digest("hex");

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
  const payload = b64url(JSON.stringify({ iss: issuer, iat: now, exp: now + 600, aud: "appstoreconnect-v1" }));
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
  if (response.status === 204) return null;
  const parsed = await response.json().catch(() => null);
  if (!response.ok) {
    throw new Error(`${method} ${path} -> ${response.status}\n${JSON.stringify(parsed?.errors ?? parsed, null, 2)}`);
  }
  return parsed;
}

function stateOf(resource) {
  return resource.attributes.state ?? resource.attributes.assetDeliveryState?.state ?? "UNKNOWN";
}

if (AUDIT_SUBMISSION || UNLOCK_SUBMISSION || RESOLVE_REJECTED_ITEM || CANCEL_SUBMISSION) {
  const subscriptionVersions = await asc("GET", `/v1/subscriptions/${SUBSCRIPTION_ID}/versions?limit=200`);
  console.log(`订阅版本: ${JSON.stringify(subscriptionVersions.data.map(({ id, attributes }) => ({ id, ...attributes })))}`);
  const groupVersions = await asc("GET", `/v1/subscriptionGroups/${SUBSCRIPTION_GROUP_ID}/versions?limit=200`);
  console.log(`订阅组版本: ${JSON.stringify(groupVersions.data.map(({ id, attributes }) => ({ id, ...attributes })))}`);
  const submissions = await asc("GET", `/v1/apps/${APP_ID}/reviewSubmissions?limit=200`);
  const unresolvedSubmissions = submissions.data.filter((submission) => submission.attributes.state === "UNRESOLVED_ISSUES");
  const unlockTargets = [];
  const rejectedTargets = [];
  for (const submission of submissions.data) {
    console.log(`审核提交 ${submission.id}: ${JSON.stringify(submission.attributes)}`);
    const items = await asc("GET", `/v1/reviewSubmissions/${submission.id}/items?limit=200`);
    for (const item of items.data) {
      const relationships = Object.fromEntries(
        Object.entries(item.relationships ?? {}).map(([name, value]) => [name, value.data ?? null]),
      );
      console.log(`  项目 ${item.id}: ${JSON.stringify({ attributes: item.attributes, relationships })}`);
      const decodedID = Buffer.from(item.id, "base64url").toString("utf8");
      const isEditableMetadataItem = item.attributes.state === "READY_FOR_REVIEW" && (
        decodedID.includes(subscriptionVersions.data[0]?.id) || decodedID.includes(groupVersions.data[0]?.id)
      );
      if (submission.attributes.state === "UNRESOLVED_ISSUES" && isEditableMetadataItem) {
        unlockTargets.push(item);
      }
      if (submission.attributes.state === "UNRESOLVED_ISSUES" && item.attributes.state === "REJECTED") {
        rejectedTargets.push(item);
      }
    }
  }
  if (UNLOCK_SUBMISSION) {
    if (unlockTargets.length !== 2) {
      throw new Error(`预计找到 2 个锁定的订阅审核项，实际为 ${unlockTargets.length} 个；停止修改`);
    }
    for (const item of unlockTargets) {
      await asc("DELETE", `/v1/reviewSubmissionItems/${item.id}`);
      console.log(`已从当前审核提交移除 ${item.id}`);
    }
  }
  if (RESOLVE_REJECTED_ITEM) {
    if (rejectedTargets.length !== 1) {
      throw new Error(`预计找到 1 个被拒的 App 审核项，实际为 ${rejectedTargets.length} 个；停止修改`);
    }
    const item = rejectedTargets[0];
    await asc("PATCH", `/v1/reviewSubmissionItems/${item.id}`, {
      data: {
        type: "reviewSubmissionItems",
        id: item.id,
        attributes: { resolved: true },
      },
    });
    console.log(`已将被拒项目切换到编辑状态 ${item.id}`);
  }
  if (CANCEL_SUBMISSION) {
    if (unresolvedSubmissions.length !== 1) {
      throw new Error(`预计找到 1 个未解决问题的审核提交，实际为 ${unresolvedSubmissions.length} 个；停止修改`);
    }
    const submission = unresolvedSubmissions[0];
    await asc("PATCH", `/v1/reviewSubmissions/${submission.id}`, {
      data: {
        type: "reviewSubmissions",
        id: submission.id,
        attributes: { canceled: true },
      },
    });
    console.log(`已取消失败的审核提交 ${submission.id}`);
  }
  process.exit(0);
}

const existing = await asc("GET", `/v1/subscriptions/${SUBSCRIPTION_ID}/images?limit=200`);
for (const item of existing.data) {
  console.log(`现有推广图 ${item.id}: ${item.attributes.fileName} (${stateOf(item)})`);
}

const alreadyCurrent = existing.data.some((item) => item.attributes.sourceFileChecksum === checksum);
if (alreadyCurrent) {
  console.log(`推广图已是最新：${checksum}`);
  process.exit(0);
}

if (!APPLY) {
  console.log(`需要替换为 ${basename(IMAGE_PATH)}，${image.length} bytes，MD5 ${checksum}`);
  process.exit(0);
}

for (const item of existing.data) {
  await asc("DELETE", `/v1/subscriptionImages/${item.id}`);
  console.log(`已删除旧推广图 ${item.id}`);
}

const reservation = await asc("POST", "/v1/subscriptionImages", {
  data: {
    type: "subscriptionImages",
    attributes: { fileSize: image.length, fileName: basename(IMAGE_PATH) },
    relationships: {
      subscription: { data: { type: "subscriptions", id: SUBSCRIPTION_ID } },
    },
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
  if (!response.ok) throw new Error(`上传推广图分片失败：${response.status} ${await response.text()}`);
}

await asc("PATCH", `/v1/subscriptionImages/${resource.id}`, {
  data: {
    type: "subscriptionImages",
    id: resource.id,
    attributes: { uploaded: true, sourceFileChecksum: checksum },
  },
});
console.log(`推广图已上传并提交：${resource.id}`);

for (let attempt = 0; attempt < 20; attempt += 1) {
  const current = (await asc("GET", `/v1/subscriptionImages/${resource.id}`)).data;
  const state = stateOf(current);
  if (state === "COMPLETE") {
    console.log("App Store Connect 已处理完成");
    process.exit(0);
  }
  if (state === "FAILED") {
    throw new Error(`App Store Connect 处理推广图失败：${JSON.stringify(current.attributes, null, 2)}`);
  }
  await new Promise((resolvePromise) => setTimeout(resolvePromise, 2_000));
}

console.log("推广图仍在异步处理中，请稍后在 App Store Connect 确认状态");
