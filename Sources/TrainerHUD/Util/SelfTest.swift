import Foundation

enum SelfTest {
    static func run() -> Bool {
        var failures = 0
        func check(_ name: String, _ cond: @autoclosure () -> Bool, _ detail: @autoclosure () -> String = "") {
            if cond() { print("ok   \(name)") } else { failures += 1; print("FAIL \(name) \(detail())") }
        }

        let zwo = """
        <workout_file><name>Test 3x1</name><sportType>bike</sportType><workout>
        <Warmup Duration="600" PowerLow="0.5" PowerHigh="0.7"/>
        <IntervalsT Repeat="3" OnDuration="60" OffDuration="30" OnPower="1.2" OffPower="0.5"/>
        <SteadyState Duration="300" Power="0.9"/>
        <FreeRide Duration="120"/>
        <Cooldown Duration="300" PowerLow="0.6" PowerHigh="0.4"/>
        </workout></workout_file>
        """
        let wo = ZWOParser.parse(Data(zwo.utf8))
        check("zwo parse", wo?.name == "Test 3x1" && wo?.steps.count == 10, "\(String(describing: wo?.steps.count))")
        check("zwo duration", wo?.totalDuration == 600 + 270 + 300 + 120 + 300, "\(String(describing: wo?.totalDuration))")
        if let wo {
            check("zwo ramp mid", abs(wo.steps[0].fraction(at: 300) - 0.6) < 1e-9)
            let p = wo.position(at: 600 + 60 + 10)
            check("zwo position", p?.index == 2 && p?.offset == 10 && wo.steps[2].kind == .off, "\(String(describing: p))")
            check("zwo free", wo.steps[8].isFree)
            check("zwo end", wo.position(at: wo.totalDuration) == nil)
            let rs = RideState(); rs.workout = wo; rs.workoutElapsed = 600 + 5
            check("zwo target", rs.workoutTargetWatts(ftp: 250) == 300, "\(String(describing: rs.workoutTargetWatts(ftp: 250)))")
        }

        let gear = ZwiftMessages.gear(ratioX10000: 24000)
        check("gear 2.40", gear == Data(hex: "04 2A 04 10 C0 BB 01"), gear.hexString)

        let gearW = ZwiftMessages.gear(ratioX10000: 24000, bikeKgX100: 831, riderKgX100: 8500)
        check("gear + weights", gearW == Data(hex: "04 2A 0A 10 C0 BB 01 20 BF 06 28 B4 42"), gearW.hexString)

        let simFull = ZwiftMessages.simulation(inclineX100: 173, full: true)
        check("sim full +1.73%", simFull == Data(hex: "04 22 0B 08 00 10 DA 02 18 EC 27 20 90 03"), simFull.hexString)

        let simNeg = ZwiftMessages.simulation(inclineX100: -85, full: false)
        check("sim −0.85%", simNeg == Data(hex: "04 22 03 10 A9 01"), simNeg.hexString)

        let simZero = ZwiftMessages.simulation(inclineX100: 0, full: false)
        check("sim 0", simZero == Data(hex: "04 22 02 10 00"), simZero.hexString)

        let td = ZwiftMessages.parseTrainerData(Data(hex: "08 BE 01 10 50 18 BD 06 20 00 28 E2 BA 01 30 8B EB 01")!)
        check("trainer data", td.power == 190 && td.cadence == 80 && td.speedX100 == 829 && td.heartRate == 0, "\(td)")

        let ride = ZwiftMessages.parseControllerNotification(Data(hex: "08 FE FF FF FF 0F 1A 04 08 00 10 00 1A 04 08 01 10 00 1A 04 08 02 10 00 1A 04 08 03 10 00")!)
        check("ride LEFT pressed", ride.buttons == [.left], "\(ride.buttons)")

        let rideIdle = ZwiftMessages.parseControllerNotification(Data(hex: "08 FF FF FF FF 0F 1A 04 08 00 10 00 1A 04 08 01 10 00")!)
        check("ride idle", rideIdle.buttons.isEmpty, "\(rideIdle.buttons)")

        func rideFrame(_ bitmap: UInt32, analog: [(Int, Int32)] = [], nested: Bool = false) -> Data {
            var w = ProtoWriter()
            w.varint(1, UInt64(bitmap))
            if nested {
                w.message(2) { g in
                    for (id, v) in analog { g.message(1) { a in a.varint(1, id); a.sint(2, v) } }
                }
            } else {
                for (id, v) in analog { w.message(3) { a in a.varint(1, id); a.sint(2, v) } }
            }
            return w.data
        }
        let plus = ZwiftMessages.parseControllerNotification(rideFrame(~RideButtons.shiftUpRight.rawValue))
        check("ride + (right shift up)", plus.buttons == [.shiftUpRight], "\(plus.buttons)")

        let minus = ZwiftMessages.parseControllerNotification(rideFrame(~RideButtons.shiftUpLeft.rawValue))
        check("ride − (left)", minus.buttons == [.shiftUpLeft], "\(minus.buttons)")

        let bButton = ZwiftMessages.parseControllerNotification(rideFrame(~(RideButtons.b.rawValue), analog: [(0, 0), (1, 0)]))
        check("ride B", bButton.buttons == [.b], "\(bButton.buttons)")

        let analog = ZwiftMessages.parseControllerNotification(rideFrame(0xFFFFFFFF, analog: [(0, -100), (1, 0)], nested: true))
        check("ride analog paddle (field 2 nested)", analog.buttons == [.paddleLeft] && analog.analog[0] == -100, "\(analog.buttons) \(analog.analog)")

        check("click plus", ZwiftMessages.parseClickKeypad(Data(hex: "08 00 10 01")!) == [.clickPlus])
        check("click minus", ZwiftMessages.parseClickKeypad(Data(hex: "08 01 10 00")!) == [.clickMinus])
        check("click idle", ZwiftMessages.parseClickKeypad(Data(hex: "08 01 10 01")!).isEmpty)

        let play = ZwiftMessages.parsePlayKeypad(Data(hex: "08 00 10 01 18 01 20 00 28 01 30 01 38 01 40 00 48 00")!)
        check("play right A", play.buttons == [.a] && !play.isLeft, "\(play.buttons)")

        check("battery", ZwiftMessages.parseBattery(Data(hex: "10 64")!) == 100)

        let info = ZwiftMessages.parseDeviceInfo(Data(hex: "08 00 12 2D 0A 2B 12 04 00 00 00 01 1A 09 5A 77 69 66 74 20 53 46 32 32 0F 30 38 2D 46 39 36 43 36 32 46 33 33 41 41 43 3A 03 42 2E 30 48 01 50 08")!)
        check("device info", info?.name == "Zwift SF2" && info?.serial == "08-F96C62F33AAC" && info?.productId == 8, "\(String(describing: info))")

        check("rideon detect", ZwiftMessages.isRideOnResponse(Data(hex: "52 69 64 65 4F 6E 02 03")!))
        check("type from mfg", ZwiftDeviceType.from(manufacturerData: Data(hex: "4A 09 0B 8B 27")) == .clickV2Left)

        let hr = HeartRateSample.parse(Data(hex: "16 8C 03 04 F2 03")!)
        check("hr uint8 + rr", hr?.bpm == 140 && hr?.contact == true && hr?.rrIntervals.count == 2, "\(String(describing: hr))")

        let cps = CyclingPowerSample.parse(Data(hex: "20 00 C8 00 34 12 00 40")!)
        check("cps crank", cps?.watts == 200 && cps?.crankRevs == 0x1234 && cps?.crankTime == 0x4000, "\(String(describing: cps))")

        let ibd = IndoorBikeData.parse(Data(hex: "44 00 A4 0B A0 00 BE 00")!)
        check("ftms indoor bike", ibd?.speedKmh == 29.8 && ibd?.cadence == 80 && ibd?.power == 190, "\(String(describing: ibd))")

        let sim = FTMSControl.simulation(gradePercent: 5, crr: 0.004, cw: 0.51)
        check("ftms sim 5%", sim == Data(hex: "11 00 00 F4 01 28 33"), sim.hexString)

        var crank = CrankTracker()
        _ = crank.update(revs: 10, time1024: 0)
        let cad = crank.update(revs: 11, time1024: 768)
        check("crank cadence 80", cad.map { abs($0 - 80) < 0.01 } ?? false, "\(String(describing: cad))")

        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        return failures == 0
    }
}
