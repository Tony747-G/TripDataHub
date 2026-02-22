const fs = require('fs');
const path = require('path');

const outputDir = path.join(process.cwd(), 'output');
const scrapePath = path.join(outputDir, 'tripboard_scrape.json');

function fail(msg) {
  console.error(msg);
  process.exit(1);
}

if (!fs.existsSync(scrapePath)) {
  fail(`Missing ${scrapePath}`);
}

const scrape = JSON.parse(fs.readFileSync(scrapePath, 'utf8'));
const load = scrape.capturedApiResponses.find(
  (r) => r.url && r.url.includes('/TripBoard/Load') && r.json
)?.json;

if (!load) {
  fail('TripBoard/Load JSON payload not found in scrape file.');
}

const payPeriods = (load.payPeriods || []).slice().sort((a, b) => {
  return new Date(a.startsOn) - new Date(b.startsOn);
});

if (!payPeriods.length) {
  fail('No pay periods found in payload.');
}

function pad2(n) {
  return String(n).padStart(2, '0');
}

function ppLabel(payPeriodId) {
  const raw = String(payPeriodId || '0000').replace(/\D/g, '');
  if (raw.length >= 4) {
    return `PP${raw.slice(0, 2)}-${raw.slice(-2)}`;
  }
  if (raw.length === 3) {
    return `PP0${raw[0]}-${raw.slice(1)}`;
  }
  if (raw.length === 2) {
    return `PP00-${raw}`;
  }
  return `PP00-${pad2(Number(raw) || 0)}`;
}

function cleanText(value) {
  return String(value || '')
    .replace(/<[^>]*>/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

function formatDateTime(raw) {
  if (!raw) return '';
  const isoish = String(raw).trim().replace('T', ' ');
  return isoish.replace(/:\d\d$/, '');
}

function toDecimalHours(credit) {
  const m = String(credit || '').match(/^(\d+):(\d{2})$/);
  if (!m) return null;
  const hh = Number(m[1]);
  const mm = Number(m[2]);
  return Math.round(((hh + mm / 60) + Number.EPSILON) * 100) / 100;
}

function normalizeTrip(trip) {
  const summary = trip.tripDetails?.tripSummary || {};
  const route = cleanText(trip.plainSubTitle || trip.subTitle || '');
  const credit = cleanText(trip.credit || '');

  return {
    pairing: cleanText(trip.pairingNumber || ''),
    title: cleanText(trip.title || ''),
    start_local: formatDateTime(trip.startsOn),
    end_local: formatDateTime(trip.endsOn),
    route,
    credit_hhmm: credit,
    credit_decimal: toDecimalHours(credit),
    seat: cleanText(trip.seat || ''),
    fleet: cleanText(trip.fleet || ''),
    domicile: cleanText(trip.domicile || ''),
    week: trip.week ?? null,
    request_type: cleanText(trip.requestType || ''),
    status_code: trip.status ?? null,
    duty_days: summary.dutyDays ?? null,
    block_hhmm: cleanText(summary.block || ''),
    time_away_from_base_hhmm: cleanText(summary.timeAwayFromBase || ''),
    total_duty_time_hhmm: cleanText(summary.totalDutyTime || ''),
  };
}

function toCsv(rows) {
  if (!rows.length) return '';
  const headers = Object.keys(rows[0]);
  const esc = (v) => {
    const s = v == null ? '' : String(v);
    return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
  };
  return [
    headers.join(','),
    ...rows.map((row) => headers.map((h) => esc(row[h])).join(',')),
  ].join('\n');
}

const manifest = [];

for (const pp of payPeriods) {
  const label = ppLabel(pp.payPeriodId);
  const schedule = (pp.scheduledTrips || []).map(normalizeTrip);
  const openTime = (pp.trips || []).map(normalizeTrip);

  const meta = {
    pay_period: {
      label,
      pay_period_id: pp.payPeriodId,
      bid_period_id: pp.bidPeriodId,
      start_local: formatDateTime(pp.startsOn),
      end_local: formatDateTime(pp.endsOn),
    },
    counts: {
      schedule: schedule.length,
      open_time: openTime.length,
    },
  };

  const scheduleJsonName = `${label}_Schedule.json`;
  const scheduleCsvName = `${label}_Schedule.csv`;
  const openJsonName = `${label}_Open_Time.json`;
  const openCsvName = `${label}_Open_Time.csv`;

  fs.writeFileSync(
    path.join(outputDir, scheduleJsonName),
    JSON.stringify({ ...meta, rows: schedule }, null, 2)
  );
  fs.writeFileSync(path.join(outputDir, scheduleCsvName), toCsv(schedule));

  fs.writeFileSync(
    path.join(outputDir, openJsonName),
    JSON.stringify({ ...meta, rows: openTime }, null, 2)
  );
  fs.writeFileSync(path.join(outputDir, openCsvName), toCsv(openTime));

  manifest.push({
    label,
    schedule_json: scheduleJsonName,
    schedule_csv: scheduleCsvName,
    open_time_json: openJsonName,
    open_time_csv: openCsvName,
    schedule_count: schedule.length,
    open_time_count: openTime.length,
  });
}

const manifestPath = path.join(outputDir, 'PP_manifest.json');
fs.writeFileSync(manifestPath, JSON.stringify({ generated_at: new Date().toISOString(), manifest }, null, 2));

console.log(`Generated ${manifest.length} pay period export sets.`);
for (const item of manifest) {
  console.log(`${item.label}: schedule=${item.schedule_count}, open_time=${item.open_time_count}`);
}
console.log(`Manifest: ${manifestPath}`);
