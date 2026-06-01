#!/usr/bin/env node

const crypto = require("crypto");
const fs = require("fs");
const https = require("https");
const path = require("path");

const DEFAULT_CONTAINER = "iCloud.com.sfune.TimelineSchedule";
const DEFAULT_DATABASE = "public";

function usage(exitCode = 0) {
  console.log(`
Usage:
  node scripts/copy_cloudkit_records.js --source-environment production --dest-environment development --record-type TDHSharedSchedule --record-name tdh_schedule_0554744 --copy

Options:
  --record-type <type>          Record type to copy.
  --record-name <name>          Exact record name to copy. Can be repeated.
  --source-environment <env>    development or production.
  --dest-environment <env>      development or production.
  --source-key-id <id>          Source Server-to-Server Key ID. Or CK_SOURCE_KEY_ID / CK_KEY_ID.
  --dest-key-id <id>            Destination Server-to-Server Key ID. Or CK_DEST_KEY_ID / CK_KEY_ID.
  --private-key <path>          EC private key PEM. Or CK_PRIVATE_KEY_PATH.
  --container <id>              CloudKit container. Default: ${DEFAULT_CONTAINER}
  --database <db>               public/private/shared. Default: ${DEFAULT_DATABASE}
  --out <path>                  Result JSON path. Default: build/cloudkit_record_copy_result.json
  --copy                        Copy records.
  --dry-run                     Fetch and write preview only.
`.trim());
  process.exit(exitCode);
}

function parseArgs(argv) {
  const args = {
    recordNames: [],
    container: DEFAULT_CONTAINER,
    database: DEFAULT_DATABASE,
    output: "build/cloudkit_record_copy_result.json",
    sourceKeyID: process.env.CK_SOURCE_KEY_ID || process.env.CK_KEY_ID,
    destKeyID: process.env.CK_DEST_KEY_ID || process.env.CK_KEY_ID,
    privateKeyPath: process.env.CK_PRIVATE_KEY_PATH,
    copy: false,
    dryRun: false,
  };

  for (let i = 2; i < argv.length; i += 1) {
    const arg = argv[i];
    const next = () => {
      i += 1;
      if (i >= argv.length) throw new Error(`Missing value for ${arg}`);
      return argv[i];
    };
    switch (arg) {
      case "--record-type": args.recordType = next(); break;
      case "--record-name": args.recordNames.push(next()); break;
      case "--source-environment": args.sourceEnvironment = next(); break;
      case "--dest-environment": args.destEnvironment = next(); break;
      case "--source-key-id": args.sourceKeyID = next(); break;
      case "--dest-key-id": args.destKeyID = next(); break;
      case "--private-key": args.privateKeyPath = next(); break;
      case "--container": args.container = next(); break;
      case "--database": args.database = next(); break;
      case "--out": args.output = next(); break;
      case "--copy": args.copy = true; break;
      case "--dry-run": args.dryRun = true; break;
      case "--help":
      case "-h": usage(0); break;
      default: throw new Error(`Unknown argument: ${arg}`);
    }
  }

  if (!args.recordType) throw new Error("--record-type is required.");
  if (args.recordNames.length === 0) throw new Error("At least one --record-name is required.");
  for (const key of ["sourceEnvironment", "destEnvironment"]) {
    if (!["development", "production"].includes(args[key])) {
      throw new Error(`--${key.replace(/[A-Z]/g, (c) => `-${c.toLowerCase()}`)} must be development or production.`);
    }
  }
  if (!["public", "private", "shared"].includes(args.database)) {
    throw new Error("--database must be public, private, or shared.");
  }
  if ([args.copy, args.dryRun].filter(Boolean).length !== 1) {
    throw new Error("Choose exactly one of --copy or --dry-run.");
  }
  if (!args.sourceKeyID || !args.destKeyID || !args.privateKeyPath) {
    throw new Error("Source/destination key IDs and --private-key/CK_PRIVATE_KEY_PATH are required.");
  }
  return args;
}

function cloudKitDate() {
  return new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
}

function cloudKitSubpath(args, environment, operation) {
  return `/database/1/${encodeURIComponent(args.container)}/${environment}/${args.database}/records/${operation}`;
}

function signHeaders({ body, subpath, keyID, privateKey }) {
  const date = cloudKitDate();
  const bodyHash = crypto.createHash("sha256").update(body, "utf8").digest("base64");
  const signer = crypto.createSign("sha256");
  signer.update(`${date}:${bodyHash}:${subpath}`);
  signer.end();
  return {
    "Content-Type": "text/plain",
    "X-Apple-CloudKit-Request-KeyID": keyID,
    "X-Apple-CloudKit-Request-ISO8601Date": date,
    "X-Apple-CloudKit-Request-SignatureV1": signer.sign(privateKey, "base64"),
  };
}

function postCloudKit(args, environment, keyID, operation, bodyObject) {
  const subpath = cloudKitSubpath(args, environment, operation);
  const body = JSON.stringify(bodyObject);
  const privateKey = fs.readFileSync(args.privateKeyPath, "utf8");
  const headers = signHeaders({ body, subpath, keyID, privateKey });
  const options = {
    hostname: "api.apple-cloudkit.com",
    path: subpath,
    method: "POST",
    headers: { ...headers, "Content-Length": Buffer.byteLength(body) },
  };

  return new Promise((resolve, reject) => {
    const request = https.request(options, (response) => {
      let responseBody = "";
      response.setEncoding("utf8");
      response.on("data", (chunk) => { responseBody += chunk; });
      response.on("end", () => {
        let json = null;
        try {
          json = responseBody ? JSON.parse(responseBody) : null;
        } catch {
          reject(new Error(`CloudKit returned non-JSON response (${response.statusCode}): ${responseBody}`));
          return;
        }
        if (response.statusCode < 200 || response.statusCode >= 300) {
          reject(new Error(`CloudKit HTTP ${response.statusCode}: ${JSON.stringify(json)}`));
          return;
        }
        resolve(json);
      });
    });
    request.on("error", reject);
    request.write(body);
    request.end();
  });
}

function copyableFields(fields) {
  const copied = {};
  for (const [key, value] of Object.entries(fields ?? {})) {
    if (key === "ownerRecordName") continue;
    copied[key] = value;
  }
  return copied;
}

async function main() {
  const args = parseArgs(process.argv);
  const lookupBody = {
    records: args.recordNames.map((recordName) => ({ recordName })),
  };
  const lookup = await postCloudKit(args, args.sourceEnvironment, args.sourceKeyID, "lookup", lookupBody);
  const found = (lookup.records ?? []).filter((record) => !record.serverErrorCode);
  const missing = (lookup.records ?? []).filter((record) => record.serverErrorCode);
  const records = found.map((record) => ({
    recordName: record.recordName,
    recordType: args.recordType,
    fields: copyableFields(record.fields),
  }));
  const modifyBody = {
    operations: records.map((record) => ({
      operationType: "forceUpdate",
      record,
    })),
  };

  let modify = null;
  if (args.copy && records.length > 0) {
    modify = await postCloudKit(args, args.destEnvironment, args.destKeyID, "modify", modifyBody);
  }

  const result = {
    sourceEnvironment: args.sourceEnvironment,
    destEnvironment: args.destEnvironment,
    recordType: args.recordType,
    found: found.map((record) => ({
      recordName: record.recordName,
      fields: Object.keys(record.fields ?? {}),
    })),
    missing,
    copied: modify?.records?.map((record) => ({
      recordName: record.recordName,
      serverErrorCode: record.serverErrorCode,
      reason: record.reason,
    })) ?? [],
  };
  fs.mkdirSync(path.dirname(args.output), { recursive: true });
  fs.writeFileSync(args.output, JSON.stringify(result, null, 2));
  console.log(JSON.stringify(result, null, 2));
}

main().catch((error) => {
  console.error(`ERROR: ${error.message}`);
  process.exit(1);
});
