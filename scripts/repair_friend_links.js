#!/usr/bin/env node

const crypto = require("crypto");
const fs = require("fs");
const https = require("https");
const path = require("path");

const DEFAULT_CONTAINER = "iCloud.com.sfune.TimelineSchedule";
const DEFAULT_ENVIRONMENT = "development";
const DEFAULT_DATABASE = "public";
const RECORD_TYPE = "TDHFriendLink";

function usage(exitCode = 0) {
  const text = `
Usage:
  node scripts/repair_friend_links.js --pair <gemsA:gemsB> --dry-run
  node scripts/repair_friend_links.js --pair <gemsA:gemsB> --upload
  node scripts/repair_friend_links.js --pair <gemsA:gemsB> --lookup
  node scripts/repair_friend_links.js --incoming <requester:recipient> --upload

Options:
  --pair <a:b>              GEMS pair to mark accepted. Can be repeated.
  --incoming <from:to>      GEMS request to mark pending from requester to recipient. Can be repeated.
  --pairs-file <path>       Text file containing one pair per line as a,b or a:b.
  --dry-run                 Write preview only; do not contact CloudKit.
  --upload                  Upload accepted TDHFriendLink records to CloudKit.
  --lookup                  Fetch matching TDHFriendLink records from CloudKit.
  --record-type <type>      Record type for generated records. Default: ${RECORD_TYPE}
  --record-name <name>      Exact record name to lookup. Can be repeated with --lookup.
  --out <path>              Preview JSON path. Default: build/friend_link_repair_preview.json
  --container <id>          CloudKit container. Default: ${DEFAULT_CONTAINER}
  --environment <env>       development or production. Default: ${DEFAULT_ENVIRONMENT}
  --database <db>           public/private/shared. Default: ${DEFAULT_DATABASE}
  --key-id <id>             CloudKit Server-to-Server Key ID. Or CK_KEY_ID env var.
  --private-key <path>      EC private key PEM. Or CK_PRIVATE_KEY_PATH env var.
  --help                    Show this help.

Example:
  CK_KEY_ID=abc123 CK_PRIVATE_KEY_PATH=~/.keys/tripdatahub-cloudkit.pem \\
  node scripts/repair_friend_links.js \\
    --environment development \\
    --pair 0000001:0000002 \\
    --upload
`;
  console.log(text.trim());
  process.exit(exitCode);
}

function parseArgs(argv) {
  const args = {
    pairs: [],
    incomingRequests: [],
    recordNames: [],
    output: "build/friend_link_repair_preview.json",
    recordType: RECORD_TYPE,
    container: DEFAULT_CONTAINER,
    environment: DEFAULT_ENVIRONMENT,
    database: DEFAULT_DATABASE,
    dryRun: false,
    upload: false,
    lookup: false,
    keyID: process.env.CK_KEY_ID,
    privateKeyPath: process.env.CK_PRIVATE_KEY_PATH,
  };

  for (let i = 2; i < argv.length; i += 1) {
    const arg = argv[i];
    const next = () => {
      i += 1;
      if (i >= argv.length) throw new Error(`Missing value for ${arg}`);
      return argv[i];
    };

    switch (arg) {
      case "--pair":
        args.pairs.push(next());
        break;
      case "--incoming":
        args.incomingRequests.push(next());
        break;
      case "--pairs-file":
        args.pairsFile = next();
        break;
      case "--record-type":
        args.recordType = next();
        break;
      case "--record-name":
        args.recordNames.push(next());
        break;
      case "--out":
        args.output = next();
        break;
      case "--container":
        args.container = next();
        break;
      case "--environment":
        args.environment = next();
        break;
      case "--database":
        args.database = next();
        break;
      case "--key-id":
        args.keyID = next();
        break;
      case "--private-key":
        args.privateKeyPath = next();
        break;
      case "--dry-run":
        args.dryRun = true;
        break;
      case "--upload":
        args.upload = true;
        break;
      case "--lookup":
        args.lookup = true;
        break;
      case "--help":
      case "-h":
        usage(0);
        break;
      default:
        throw new Error(`Unknown argument: ${arg}`);
    }
  }

  if (args.pairsFile) {
    const filePairs = fs
      .readFileSync(args.pairsFile, "utf8")
      .split(/\r?\n/)
      .map((line) => line.trim())
      .filter((line) => line && !line.startsWith("#"));
    args.pairs.push(...filePairs);
  }
  if (args.pairs.length === 0 && args.incomingRequests.length === 0 && args.recordNames.length === 0) {
    throw new Error("At least one --pair, --incoming, --record-name, or --pairs-file entry is required.");
  }
  if (args.lookup && args.incomingRequests.length > 0) {
    args.pairs.push(...args.incomingRequests);
    args.incomingRequests = [];
  }
  const actionCount = [args.dryRun, args.upload, args.lookup].filter(Boolean).length;
  if (actionCount !== 1) {
    throw new Error("Choose exactly one of --dry-run, --upload, or --lookup.");
  }
  if (!["development", "production"].includes(args.environment)) {
    throw new Error("--environment must be development or production.");
  }
  if (!["public", "private", "shared"].includes(args.database)) {
    throw new Error("--database must be public, private, or shared.");
  }
  if ((args.upload || args.lookup) && (!args.keyID || !args.privateKeyPath)) {
    throw new Error("--upload/--lookup requires --key-id/CK_KEY_ID and --private-key/CK_PRIVATE_KEY_PATH.");
  }
  return args;
}

function normalizeGEMSID(raw) {
  const digits = String(raw ?? "").replace(/\D/g, "");
  if (!digits) throw new Error(`Invalid GEMS ID: ${raw}`);
  return digits.padStart(7, "0");
}

function orderedPair(a, b) {
  const first = normalizeGEMSID(a);
  const second = normalizeGEMSID(b);
  if (first === second) throw new Error(`Self friend link is invalid: ${first}`);
  return first < second ? [first, second] : [second, first];
}

function parsePair(raw) {
  const parts = String(raw).split(/[,:]/).map((part) => part.trim()).filter(Boolean);
  if (parts.length !== 2) throw new Error(`Invalid pair "${raw}". Use GEMS_A:GEMS_B.`);
  return orderedPair(parts[0], parts[1]);
}

function parseDirectedPair(raw) {
  const parts = String(raw).split(/[,:]/).map((part) => part.trim()).filter(Boolean);
  if (parts.length !== 2) throw new Error(`Invalid incoming request "${raw}". Use REQUESTER:RECIPIENT.`);
  const requester = normalizeGEMSID(parts[0]);
  const recipient = normalizeGEMSID(parts[1]);
  if (requester === recipient) throw new Error(`Self friend request is invalid: ${requester}`);
  return { requester, recipient, ordered: orderedPair(requester, recipient) };
}

function friendLinkRecordName(first, second) {
  return `tdh_friend_${first}_${second}`;
}

function cloudKitTimestamp(date) {
  return date.getTime();
}

function prepareAcceptedRecords(pairInputs) {
  const now = new Date();
  const seen = new Set();
  return pairInputs.map(parsePair).filter(([first, second]) => {
    const key = `${first}:${second}`;
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  }).map(([first, second]) => ({
    recordName: friendLinkRecordName(first, second),
    recordType: RECORD_TYPE,
    fields: {
      gemsA: { value: first },
      gemsB: { value: second },
      approvedA: { value: 1, type: "INT64" },
      approvedB: { value: 1, type: "INT64" },
      status: { value: "accepted" },
      linkedAt: { value: cloudKitTimestamp(now), type: "TIMESTAMP" },
      updatedAt: { value: cloudKitTimestamp(now), type: "TIMESTAMP" },
    },
  }));
}

function prepareIncomingRecords(incomingInputs) {
  const now = new Date();
  const seen = new Set();
  return incomingInputs.map(parseDirectedPair).filter(({ ordered: [first, second] }) => {
    const key = `${first}:${second}`;
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  }).map(({ requester, recipient, ordered: [first, second] }) => {
    const requesterIsA = requester === first;
    return {
      recordName: friendLinkRecordName(first, second),
      recordType: RECORD_TYPE,
      repairStatus: "pending",
      fields: {
        gemsA: { value: first },
        gemsB: { value: second },
        approvedA: { value: requesterIsA ? 1 : 0, type: "INT64" },
        approvedB: { value: requesterIsA ? 0 : 1, type: "INT64" },
        requesterGEMSID: { value: requester },
        recipientGEMSID: { value: recipient },
        status: { value: "pending" },
        linkedAt: { value: null },
        requestedAt: { value: cloudKitTimestamp(now), type: "TIMESTAMP" },
        updatedAt: { value: cloudKitTimestamp(now), type: "TIMESTAMP" },
      },
    };
  });
}

function prepareLookupRecords(recordNames, recordType) {
  return recordNames.map((recordName) => ({
    recordName,
    recordType,
    repairStatus: "lookup",
    fields: {},
  }));
}

function cloudKitBody(records) {
  return JSON.stringify({
    operations: records.map((record) => ({
      operationType: "forceUpdate",
      record: {
        recordName: record.recordName,
        recordType: record.recordType,
        fields: record.fields,
      },
    })),
  });
}

function cloudKitLookupBody(records) {
  return JSON.stringify({
    records: records.map((record) => ({
      recordName: record.recordName,
    })),
  });
}

function cloudKitSubpath(args, operation = "modify") {
  return `/database/1/${encodeURIComponent(args.container)}/${args.environment}/${args.database}/records/${operation}`;
}

function cloudKitDate() {
  return new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
}

function signHeaders({ body, subpath, keyID, privateKey }) {
  const date = cloudKitDate();
  const bodyHash = crypto.createHash("sha256").update(body, "utf8").digest("base64");
  const message = `${date}:${bodyHash}:${subpath}`;
  const signer = crypto.createSign("sha256");
  signer.update(message);
  signer.end();
  return {
    "Content-Type": "text/plain",
    "X-Apple-CloudKit-Request-KeyID": keyID,
    "X-Apple-CloudKit-Request-ISO8601Date": date,
    "X-Apple-CloudKit-Request-SignatureV1": signer.sign(privateKey, "base64"),
  };
}

function postCloudKit(args, records, operation = "modify") {
  const subpath = cloudKitSubpath(args, operation);
  const body = operation === "lookup" ? cloudKitLookupBody(records) : cloudKitBody(records);
  const privateKey = fs.readFileSync(args.privateKeyPath, "utf8");
  const headers = signHeaders({ body, subpath, keyID: args.keyID, privateKey });
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
        } catch (error) {
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

function writePreview(outputPath, args, records) {
  fs.mkdirSync(path.dirname(outputPath), { recursive: true });
  fs.writeFileSync(outputPath, JSON.stringify({
    container: args.container,
    environment: args.environment,
    database: args.database,
    recordType: args.recordType,
    count: records.length,
    records,
  }, null, 2));
}

async function main() {
  const args = parseArgs(process.argv);
  const records = [
    ...prepareAcceptedRecords(args.pairs),
    ...prepareIncomingRecords(args.incomingRequests),
    ...prepareLookupRecords(args.recordNames, args.recordType),
  ];
  writePreview(args.output, args, records);
  console.log(`Prepared ${records.length} ${RECORD_TYPE} repair record(s).`);
  console.log(`Preview written to ${args.output}`);
  for (const record of records) {
    console.log(`- ${record.recordName}: ${record.repairStatus ?? "accepted"}`);
  }
  if (args.dryRun) {
    console.log("Dry run complete. No CloudKit upload was performed.");
    return;
  }
  if (args.lookup) {
    const response = await postCloudKit(args, records, "lookup");
    console.log(JSON.stringify(response, null, 2));
    return;
  }
  const response = await postCloudKit(args, records);
  const failures = (response.records ?? []).filter((record) => record.serverErrorCode);
  if (failures.length > 0) {
    throw new Error(`CloudKit repair failed: ${JSON.stringify(failures, null, 2)}`);
  }
  console.log("CloudKit friend link repair complete.");
}

main().catch((error) => {
  console.error(`ERROR: ${error.message}`);
  process.exit(1);
});
