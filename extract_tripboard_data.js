const fs = require('fs');
const path = require('path');

const root = path.join(process.cwd(), 'output');
const src = JSON.parse(fs.readFileSync(path.join(root, 'tripboard_scrape.json'), 'utf8'));
const load = src.capturedApiResponses.find(
  (r) => r.url.includes('/TripBoard/Load') && r.json
)?.json;

if (!load) {
  throw new Error('TripBoard/Load payload not found');
}

const today = new Date();
const payPeriods = load.payPeriods || [];
const current =
  payPeriods.find((p) => new Date(p.startsOn) <= today && today <= new Date(p.endsOn)) ||
  payPeriods[0] ||
  {};

const toRec = (t) => ({
  pairing: t.pairingNumber,
  start: t.startsOn,
  end: t.endsOn,
  title: t.title,
  route: (t.plainSubTitle || '').trim(),
  credit: t.credit,
  creditValue: t.creditValue,
  domicile: t.domicile,
  fleet: t.fleet,
  seat: t.seat,
  week: t.week,
  requestType: t.requestType,
  status: t.status,
});

const schedule = (current.scheduledTrips || []).map(toRec);
const openTime = (current.trips || []).map(toRec);

const result = {
  capturedAt: new Date().toISOString(),
  pilot: load.pilot,
  payPeriod: {
    id: current.payPeriodId,
    bidPeriodId: current.bidPeriodId,
    startsOn: current.startsOn,
    endsOn: current.endsOn,
  },
  counts: {
    schedule: schedule.length,
    openTime: openTime.length,
  },
  schedule,
  openTime,
};

fs.writeFileSync(path.join(root, 'extracted_schedule_open_time.json'), JSON.stringify(result, null, 2));

function toCsv(rows) {
  const headers = [
    'pairing',
    'start',
    'end',
    'title',
    'route',
    'credit',
    'creditValue',
    'domicile',
    'fleet',
    'seat',
    'week',
    'requestType',
    'status',
  ];

  const escapeCell = (v) => {
    const s = v == null ? '' : String(v);
    if (/[",\n]/.test(s)) return `"${s.replace(/"/g, '""')}"`;
    return s;
  };

  return [
    headers.join(','),
    ...rows.map((row) => headers.map((h) => escapeCell(row[h])).join(',')),
  ].join('\n');
}

fs.writeFileSync(path.join(root, 'schedule.csv'), toCsv(schedule));
fs.writeFileSync(path.join(root, 'open_time.csv'), toCsv(openTime));

console.log(`wrote ${path.join(root, 'extracted_schedule_open_time.json')}`);
console.log(`schedule ${schedule.length} openTime ${openTime.length}`);
