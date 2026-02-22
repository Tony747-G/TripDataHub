const fs = require('fs');

const pairing = process.argv[2] || 'A70878';
const state = JSON.parse(fs.readFileSync('storageState.json', 'utf8'));
const cookies = (state.cookies || [])
  .filter(c => /bidproplus\.com$/.test(c.domain.replace(/^\./, '')))
  .map(c => `${c.name}=${c.value}`)
  .join('; ');

if (!cookies) {
  throw new Error('No bidproplus cookies found in storageState.json');
}

async function main() {
  const res = await fetch('https://tripboard.bidproplus.com/api/1.0/TripBoard/Load', {
    method: 'GET',
    headers: {
      'Cookie': cookies,
      'Accept': 'application/json, text/plain, */*',
      'Referer': 'https://tripboard.bidproplus.com/',
      'User-Agent': 'Mozilla/5.0'
    }
  });

  if (!res.ok) {
    throw new Error(`TripBoard/Load failed: ${res.status}`);
  }

  const data = await res.json();
  const payPeriods = data.payPeriods || [];

  let found = null;
  for (const pp of payPeriods) {
    for (const listName of ['scheduledTrips', 'trips']) {
      for (const t of (pp[listName] || [])) {
        if (String(t.pairingNumber).trim() === pairing) {
          found = { payPeriod: pp, listName, trip: t };
          break;
        }
      }
      if (found) break;
    }
    if (found) break;
  }

  if (!found) {
    console.log(JSON.stringify({ pairing, found: false }, null, 2));
    return;
  }

  const trip = found.trip;
  const duties = trip.tripDetails?.tripDuties || [];
  const legs = [];

  for (const duty of duties) {
    for (const leg of (duty.tripLegs || [])) {
      legs.push({
        flight_number: leg.flightNum || leg.flightNumber || '',
        dep_airport: leg.departure || leg.from || leg.departureAirport || leg.orig || '',
        dep_time_local: leg.startsOn || leg.departsOn || leg.departureTime || '',
        arr_airport: leg.arrival || leg.to || leg.arrivalAirport || leg.dest || '',
        arr_time_local: leg.endsOn || leg.arrivesOn || leg.arrivalTime || '',
        status: leg.status || ''
      });
    }
  }

  const out = {
    pairing: trip.pairingNumber,
    title: trip.title,
    route: trip.plainSubTitle,
    startsOn: trip.startsOn,
    endsOn: trip.endsOn,
    credit: trip.credit,
    payPeriodId: found.payPeriod.payPeriodId,
    periodStart: found.payPeriod.startsOn,
    periodEnd: found.payPeriod.endsOn,
    sourceList: found.listName,
    legs,
    sampleLegKeys: duties[0]?.tripLegs?.[0] ? Object.keys(duties[0].tripLegs[0]) : []
  };

  console.log(JSON.stringify(out, null, 2));
}

main().catch((e) => {
  console.error(e.message);
  process.exit(1);
});
