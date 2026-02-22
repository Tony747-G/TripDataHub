const fs = require('fs');
const path = require('path');

const root = path.join(process.cwd(), 'output');
const src = JSON.parse(fs.readFileSync(path.join(root, 'tripboard_scrape.json'), 'utf8'));
const load = src.capturedApiResponses.find((r) => r.url.includes('/TripBoard/Load') && r.json)?.json;

if (!load) throw new Error('TripBoard/Load payload not found');

const payPeriods = load.payPeriods || [];
if (payPeriods.length < 2) throw new Error('Next pay period not found in payload');

const sorted = [...payPeriods].sort((a, b) => new Date(a.startsOn) - new Date(b.startsOn));
const now = new Date();
const currentIdx = sorted.findIndex((p) => new Date(p.startsOn) <= now && now <= new Date(p.endsOn));
const next = currentIdx >= 0 && currentIdx + 1 < sorted.length ? sorted[currentIdx + 1] : sorted[1];

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

const schedule = (next.scheduledTrips || []).map(toRec);
const openTime = (next.trips || []).map(toRec);

const out = {
  capturedAt: new Date().toISOString(),
  pilot: load.pilot,
  payPeriod: {
    id: next.payPeriodId,
    bidPeriodId: next.bidPeriodId,
    startsOn: next.startsOn,
    endsOn: next.endsOn,
  },
  counts: {
    schedule: schedule.length,
    openTime: openTime.length,
  },
  schedule,
  openTime,
};

function toCsv(rows) {
  const headers = ['pairing','start','end','title','route','credit','creditValue','domicile','fleet','seat','week','requestType','status'];
  const esc = (v) => {
    const s = v == null ? '' : String(v);
    return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
  };
  return [headers.join(','), ...rows.map((row) => headers.map((h) => esc(row[h])).join(','))].join('\n');
}

fs.writeFileSync(path.join(root, 'next_payperiod_schedule_open_time.json'), JSON.stringify(out, null, 2));
fs.writeFileSync(path.join(root, 'next_payperiod_schedule.csv'), toCsv(schedule));
fs.writeFileSync(path.join(root, 'next_payperiod_open_time.csv'), toCsv(openTime));

console.log(`next pay period: ${next.startsOn} -> ${next.endsOn}`);
console.log(`schedule=${schedule.length} openTime=${openTime.length}`);
