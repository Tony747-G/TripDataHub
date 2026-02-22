const fs = require('fs');
const path = require('path');

const pairing = process.argv[2] || 'A70878';
const outDir = path.join(process.cwd(), 'output');

function fmt(dt) {
  const y = dt.getFullYear();
  const m = String(dt.getMonth() + 1).padStart(2, '0');
  const d = String(dt.getDate()).padStart(2, '0');
  const hh = String(dt.getHours()).padStart(2, '0');
  const mm = String(dt.getMinutes()).padStart(2, '0');
  return `${y}-${m}-${d} ${hh}:${mm}`;
}

function parseEndHm(raw) {
  const m = String(raw || '').match(/(\d{2}):(\d{2})$/);
  if (!m) return null;
  return { h: Number(m[1]), m: Number(m[2]) };
}

function chooseArrival(depDate, nextDepDate, endHm) {
  if (!endHm) return null;
  const base = new Date(depDate);
  let best = null;

  for (let offset = -1; offset <= 6; offset += 1) {
    const c = new Date(base);
    c.setDate(c.getDate() + offset);
    c.setHours(endHm.h, endHm.m, 0, 0);

    const tooEarly = c.getTime() < depDate.getTime() - 12 * 3600 * 1000;
    const tooLate = nextDepDate && c.getTime() > nextDepDate.getTime() + 48 * 3600 * 1000;
    if (tooEarly || tooLate) continue;

    if (c.getTime() >= depDate.getTime()) {
      if (!best || c.getTime() < best.getTime()) best = c;
    }
  }

  return best;
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
    ...rows.map((r) => headers.map((h) => esc(r[h])).join(',')),
  ].join('\n');
}

async function loadTripBoard() {
  const state = JSON.parse(fs.readFileSync('storageState.json', 'utf8'));
  const cookies = (state.cookies || [])
    .filter((c) => /bidproplus\.com$/.test(c.domain.replace(/^\./, '')))
    .map((c) => `${c.name}=${c.value}`)
    .join('; ');

  const res = await fetch('https://tripboard.bidproplus.com/api/1.0/TripBoard/Load', {
    headers: {
      Cookie: cookies,
      Accept: 'application/json, text/plain, */*',
      Referer: 'https://tripboard.bidproplus.com/',
      'User-Agent': 'Mozilla/5.0',
    },
  });

  if (!res.ok) {
    throw new Error(`TripBoard/Load failed: ${res.status}`);
  }
  return res.json();
}

async function main() {
  const data = await loadTripBoard();

  let trip = null;
  let payPeriod = null;
  for (const pp of (data.payPeriods || [])) {
    const hit = (pp.scheduledTrips || []).find((t) => String(t.pairingNumber).trim() === pairing)
      || (pp.trips || []).find((t) => String(t.pairingNumber).trim() === pairing);
    if (hit) {
      trip = hit;
      payPeriod = pp;
      break;
    }
  }

  if (!trip) {
    throw new Error(`Pairing ${pairing} not found`);
  }

  const rawLegs = (trip.tripDetails?.tripDuties || []).flatMap((d) => d.tripLegs || []);
  const tripEnd = new Date(trip.endsOn);

  const rows = rawLegs.map((l, i) => {
    const depDate = new Date(l.startsOn);
    const nextDep = rawLegs[i + 1] ? new Date(rawLegs[i + 1].startsOn) : tripEnd;
    const endHm = parseEndHm(l.endTime);
    const arrDate = chooseArrival(depDate, nextDep, endHm) || (i === rawLegs.length - 1 ? tripEnd : null);

    return {
      leg: i + 1,
      flight: l.flightNumber || '',
      dep_airport: l.origin || '',
      dep_local: fmt(depDate),
      arr_airport: l.destination || '',
      arr_local: arrDate ? fmt(arrDate) : '',
      status: String(l.status || '').trim() || '-',
      block: l.block || '',
      raw_dep_token: l.startTime || '',
      raw_arr_token: l.endTime || '',
    };
  });

  const ppLabel = String(payPeriod.payPeriodId || '0000').replace(/\D/g, '');
  const label = ppLabel.length >= 4 ? `PP${ppLabel.slice(0, 2)}-${ppLabel.slice(-2)}` : `PP00-${ppLabel.padStart(2, '0')}`;

  const outJson = path.join(outDir, `${label}_${pairing}_Legs.json`);
  const outCsv = path.join(outDir, `${label}_${pairing}_Legs.csv`);

  const payload = {
    pairing: trip.pairingNumber,
    title: trip.title,
    pay_period: {
      label,
      pay_period_id: payPeriod.payPeriodId,
      start_local: payPeriod.startsOn,
      end_local: payPeriod.endsOn,
    },
    trip_start_local: trip.startsOn,
    trip_end_local: trip.endsOn,
    route: (trip.plainSubTitle || '').trim(),
    rows,
  };

  fs.writeFileSync(outJson, JSON.stringify(payload, null, 2));
  fs.writeFileSync(outCsv, toCsv(rows));

  console.log(`Wrote ${outJson}`);
  console.log(`Wrote ${outCsv}`);
  console.log(JSON.stringify(rows, null, 2));
}

main().catch((e) => {
  console.error(e.message);
  process.exit(1);
});
