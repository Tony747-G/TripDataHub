#if DEBUG
import Foundation

extension AppViewModel {
    static var previewSchedules: [PayPeriodSchedule] {
        let legs2602 = [
            TripLeg(
                payPeriod: "PP26-02",
                pairing: "51311",
                leg: 1,
                flight: "110",
                depAirport: "ANC",
                depLocal: "2026-01-25 06:15",
                arrAirport: "NRT",
                arrLocal: "2026-01-26 07:55",
                status: "DH",
                block: "7:40"
            )
        ]
        let open2602 = [
            OpenTimeTrip(
                payPeriod: "PP26-02",
                pairing: "A70330R",
                startLocal: "2026-02-17 22:23",
                endLocal: "2026-02-24 22:23",
                route: "ANC SDF DWC SZX",
                credit: "44:48",
                requestType: "PC",
                status: "-"
            )
        ]
        let legs2603 = [
            TripLeg(
                payPeriod: "PP26-03",
                pairing: "A70878",
                leg: 3,
                flight: "184",
                depAirport: "NRT",
                depLocal: "2026-03-08 20:20",
                arrAirport: "HNL",
                arrLocal: "2026-03-08 08:10",
                status: "CML",
                block: "6:50"
            )
        ]
        let open2603 = [
            OpenTimeTrip(
                payPeriod: "PP26-03",
                pairing: "A70788",
                startLocal: "2026-02-23 22:01",
                endLocal: "2026-03-03 22:23",
                route: "ANC SDF DWC CGN HKG",
                credit: "51:18",
                requestType: "PO",
                status: "-"
            )
        ]

        return [
            PayPeriodSchedule(
                id: "PP26-02",
                label: "PP26-02",
                tripCount: 2,
                legCount: 4,
                openTimeCount: 7,
                updatedAt: Date(),
                legs: legs2602,
                openTimeTrips: open2602
            ),
            PayPeriodSchedule(
                id: "PP26-03",
                label: "PP26-03",
                tripCount: 2,
                legCount: 9,
                openTimeCount: 60,
                updatedAt: Date(),
                legs: legs2603,
                openTimeTrips: open2603
            )
        ]
    }
}
#endif
