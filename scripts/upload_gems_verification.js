#!/usr/bin/env node

const crypto = require("crypto");
const fs = require("fs");
const https = require("https");
const path = require("path");

const DEFAULT_CONTAINER = "iCloud.com.sfune.TimelineSchedule";
const DEFAULT_ENVIRONMENT = "development";
const DEFAULT_DATABASE = "public";
const RECORD_TYPE = "TDHGEMSVerification";
const HASH_PREFIX = "TDH_GEMS_VERIFY_V1";
const HASH_PEPPER = "TripDataHub-GEMSVerification-v1";
const SCHEMA_VERSION = 2;
const BATCH_SIZE = 50;
const SUPPORTED_DOMICILES = new Set(["ANC", "SDF", "SDFZ", "ONT", "MIA"]);

function usage(exitCode = 0) {
  const text = `
Usage:
  node scripts/upload_gems_verification.js --csv <path> --dry-run --out <path>
  node scripts/upload_gems_verification.js --csv <path> --upload

Options:
  --csv <path>              Source seniority CSV. Expected columns: GEMS, DOB, DOM/DOMICILE/BASE.
  --dry-run                 Parse and hash records, but do not contact CloudKit.
  --upload                  Upload records to CloudKit using server-to-server auth.
  --out <path>              Write prepared record preview JSON. Default: build/gems_verification_records.json
  --container <id>          CloudKit container. Default: ${DEFAULT_CONTAINER}
  --environment <env>       development or production. Default: ${DEFAULT_ENVIRONMENT}
  --database <db>           public/private/shared. Default: ${DEFAULT_DATABASE}
  --key-id <id>             CloudKit Server-to-Server Key ID. Or CK_KEY_ID env var.
  --private-key <path>      EC private key PEM. Or CK_PRIVATE_KEY_PATH env var.
  --batch-size <number>     Upload batch size. Default: ${BATCH_SIZE}
  --help                    Show this help.

Examples:
  node scripts/upload_gems_verification.js \\
    --csv 2026-05_seniority.csv \\
    --dry-run \\
    --out build/gems_verification_preview.json

  CK_KEY_ID=abc123 CK_PRIVATE_KEY_PATH=~/.keys/tripdatahub-cloudkit.pem \\
  node scripts/upload_gems_verification.js \\
    --csv 2026-05_seniority.csv \\
    --environment development \\
    --upload
`;
  console.log(text.trim());
  process.exit(exitCode);
}

function parseArgs(argv) {
  const args = {
    container: DEFAULT_CONTAINER,
    environment: DEFAULT_ENVIRONMENT,
    database: DEFAULT_DATABASE,
    output: "build/gems_verification_records.json",
    batchSize: BATCH_SIZE,
    dryRun: false,
    upload: false,
    keyID: process.env.CK_KEY_ID,
    privateKeyPath: process.env.CK_PRIVATE_KEY_PATH,
  };

  for (let i = 2; i < argv.length; i += 1) {
    const arg = argv[i];
    const next = () => {
      i += 1;
      if (i >= argv.length) {
        throw new Error(`Missing value for ${arg}`);
      }
      return argv[i];
    };

    switch (arg) {
      case "--csv":
        args.csv = next();
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
      case "--batch-size":
        args.batchSize = Number(next());
        break;
      case "--dry-run":
        args.dryRun = true;
        break;
      case "--upload":
        args.upload = true;
        break;
      case "--help":
      case "-h":
        usage(0);
        break;
      default:
        throw new Error(`Unknown argument: ${arg}`);
    }
  }

  if (!args.csv) {
    throw new Error("--csv is required.");
  }
  if (args.dryRun === args.upload) {
    throw new Error("Choose exactly one of --dry-run or --upload.");
  }
  if (!Number.isInteger(args.batchSize) || args.batchSize < 1 || args.batchSize > 200) {
    throw new Error("--batch-size must be an integer from 1 to 200.");
  }
  if (!["development", "production"].includes(args.environment)) {
    throw new Error("--environment must be development or production.");
  }
  if (!["public", "private", "shared"].includes(args.database)) {
    throw new Error("--database must be public, private, or shared.");
  }
  if (args.upload && (!args.keyID || !args.privateKeyPath)) {
    throw new Error("--upload requires --key-id/CK_KEY_ID and --private-key/CK_PRIVATE_KEY_PATH.");
  }

  return args;
}

function parseCSVLine(line) {
  const fields = [];
  let current = "";
  let quoted = false;

  for (let i = 0; i < line.length; i += 1) {
    const ch = line[i];
    if (ch === '"') {
      if (quoted && line[i + 1] === '"') {
        current += '"';
        i += 1;
      } else {
        quoted = !quoted;
      }
    } else if (ch === "," && !quoted) {
      fields.push(current);
      current = "";
    } else {
      current += ch;
    }
  }
  fields.push(current);
  return fields;
}

function parseCSV(text) {
  return text
    .replace(/\r\n/g, "\n")
    .replace(/\r/g, "\n")
    .split("\n")
    .filter((line) => line.trim().length > 0)
    .map(parseCSVLine);
}

function normalizeGEMSID(raw) {
  const trimmed = String(raw ?? "").trim();
  if (/^[0-9]{6}$/.test(trimmed)) {
    return `0${trimmed}`;
  }
  return trimmed;
}

function normalizeDomicile(raw) {
  const normalized = String(raw ?? "").trim().toUpperCase();
  return SUPPORTED_DOMICILES.has(normalized) ? normalized : "ANC";
}

function normalizeDOB(raw) {
  const trimmed = String(raw ?? "").trim();
  const parts = trimmed.split(/[\/\-. ]+/).filter(Boolean);
  if (parts.length !== 3) {
    return null;
  }

  const month = Number(parts[0]);
  const day = Number(parts[1]);
  const yearRaw = Number(parts[2]);
  if (!Number.isInteger(month) || !Number.isInteger(day) || !Number.isInteger(yearRaw)) {
    return null;
  }
  if (month < 1 || month > 12 || day < 1 || day > 31) {
    return null;
  }

  let fullYear;
  if (parts[2].length === 2) {
    const currentYearTwoDigits = new Date().getFullYear() % 100;
    fullYear = yearRaw > currentYearTwoDigits ? 1900 + yearRaw : 2000 + yearRaw;
  } else if (parts[2].length === 4) {
    fullYear = yearRaw;
  } else {
    return null;
  }

  return `${String(month).padStart(2, "0")}/${String(day).padStart(2, "0")}/${String(fullYear).padStart(4, "0")}`;
}

function verificationHash(gemsID, normalizedDOB) {
  const payload = `${HASH_PREFIX}|${normalizeGEMSID(gemsID)}|${normalizedDOB}|${HASH_PEPPER}`;
  return crypto.createHash("sha256").update(payload, "utf8").digest("hex");
}

function field(value, type) {
  return { value, type };
}

function recordName(gemsID) {
  return `tdh_verify_${normalizeGEMSID(gemsID)}`;
}

function preparedRecord(row, nowMillis) {
  const gemsID = normalizeGEMSID(row.gemsID);
  const normalizedDOB = normalizeDOB(row.dob);
  if (!gemsID || !normalizedDOB) {
    return null;
  }
  const domicile = normalizeDomicile(row.domicile);
  return {
    recordName: recordName(gemsID),
    recordType: RECORD_TYPE,
    fields: {
      gemsID: field(gemsID, "STRING"),
      dobHash: field(verificationHash(gemsID, normalizedDOB), "STRING"),
      domicile: field(domicile, "STRING"),
      schemaVersion: field(SCHEMA_VERSION, "INT64"),
      updatedAt: field(nowMillis, "TIMESTAMP"),
    },
    preview: {
      gemsID,
      domicile,
      normalizedDOB,
      dobHash: verificationHash(gemsID, normalizedDOB),
    },
  };
}

function loadRecords(csvPath) {
  const text = fs.readFileSync(csvPath, "utf8");
  const rows = parseCSV(text);
  if (rows.length === 0) {
    throw new Error("CSV is empty.");
  }

  const header = rows[0].map((value) => value.trim().toUpperCase());
  const headerMap = new Map();
  header.forEach((name, index) => {
    if (name && !headerMap.has(name)) {
      headerMap.set(name, index);
    }
  });

  const gemsIndex = headerMap.get("GEMS");
  const dobIndex = headerMap.get("DOB");
  const domicileIndex = headerMap.get("DOM") ?? headerMap.get("DOMICILE") ?? headerMap.get("BASE");
  if (gemsIndex === undefined || dobIndex === undefined) {
    throw new Error("CSV must include GEMS and DOB columns.");
  }

  const nowMillis = Date.now();
  const seen = new Set();
  const records = [];
  const skipped = [];

  rows.slice(1).forEach((fields, offset) => {
    const lineNumber = offset + 2;
    const gemsID = fields[gemsIndex] ?? "";
    const dob = fields[dobIndex] ?? "";
    const domicile = domicileIndex === undefined ? "ANC" : fields[domicileIndex] ?? "ANC";
    const prepared = preparedRecord({ gemsID, dob, domicile }, nowMillis);
    if (!prepared) {
      skipped.push({ lineNumber, reason: "invalid gems or dob" });
      return;
    }
    if (seen.has(prepared.preview.gemsID)) {
      skipped.push({ lineNumber, reason: `duplicate GEMS ${prepared.preview.gemsID}` });
      return;
    }
    seen.add(prepared.preview.gemsID);
    records.push(prepared);
  });

  return { records, skipped };
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

function cloudKitSubpath(args) {
  return `/database/1/${encodeURIComponent(args.container)}/${args.environment}/${args.database}/records/modify`;
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

function postCloudKit(args, records) {
  const subpath = cloudKitSubpath(args);
  const body = cloudKitBody(records);
  const privateKey = fs.readFileSync(args.privateKeyPath, "utf8");
  const headers = signHeaders({ body, subpath, keyID: args.keyID, privateKey });

  const options = {
    hostname: "api.apple-cloudkit.com",
    path: subpath,
    method: "POST",
    headers: {
      ...headers,
      "Content-Length": Buffer.byteLength(body),
    },
  };

  return new Promise((resolve, reject) => {
    const request = https.request(options, (response) => {
      let responseBody = "";
      response.setEncoding("utf8");
      response.on("data", (chunk) => {
        responseBody += chunk;
      });
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

function writePreview(outputPath, records, skipped) {
  const dir = path.dirname(outputPath);
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(
    outputPath,
    JSON.stringify(
      {
        generatedAt: new Date().toISOString(),
        recordType: RECORD_TYPE,
        count: records.length,
        skipped,
        records: records.map((record) => ({
          recordName: record.recordName,
          recordType: record.recordType,
          fields: record.fields,
          preview: record.preview,
        })),
      },
      null,
      2
    )
  );
}

async function main() {
  const args = parseArgs(process.argv);
  const { records, skipped } = loadRecords(args.csv);
  writePreview(args.output, records, skipped);

  console.log(`Prepared ${records.length} ${RECORD_TYPE} records.`);
  console.log(`Skipped ${skipped.length} rows.`);
  console.log(`Preview written to ${args.output}`);

  if (args.dryRun) {
    console.log("Dry run complete. No CloudKit upload was performed.");
    return;
  }

  let uploaded = 0;
  for (let start = 0; start < records.length; start += args.batchSize) {
    const batch = records.slice(start, start + args.batchSize);
    const response = await postCloudKit(args, batch);
    const resultRecords = response.records ?? [];
    const failures = resultRecords.filter((record) => record.serverErrorCode);
    if (failures.length > 0) {
      throw new Error(`CloudKit batch failed: ${JSON.stringify(failures, null, 2)}`);
    }
    uploaded += batch.length;
    console.log(`Uploaded ${uploaded} / ${records.length}`);
  }
  console.log("CloudKit upload complete.");
}

main().catch((error) => {
  console.error(`ERROR: ${error.message}`);
  process.exit(1);
});
