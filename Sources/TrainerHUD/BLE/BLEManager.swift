import Foundation
import CoreBluetooth

struct DiscoveredDevice {
    let peripheral: CBPeripheral
    var name: String
    var rssi: Int
    var services: Set<CBUUID>
    var zwiftType: ZwiftDeviceType?
    var lastSeen: Date

    var id: UUID { peripheral.identifier }

    var roles: [DeviceRole] {
        var r: [DeviceRole] = []
        let lower = name.lowercased()
        let looksLikeController = zwiftType?.isController == true
            || ["zwift click", "zwift play", "zwift ride", "zwift sf2"].contains { lower.contains($0) }
        if looksLikeController { r.append(.controller) }
        if services.contains(GATT.ftms) || zwiftType == .hub { r.append(.trainer) }
        if services.contains(GATT.cyclingPower) {
            if !r.contains(.trainer) { r.append(.powerMeter); r.append(.trainer) } else { r.append(.powerMeter) }
        }
        if services.contains(GATT.heartRate) { r.append(.heartRate) }
        if r.isEmpty, (services.contains(ZwiftUUID.service) || services.contains(ZwiftUUID.serviceFC82)) { r.append(.controller) }
        return r
    }

    var isCyclingRelevant: Bool { !roles.isEmpty }
}

final class BLEManager: NSObject, CBCentralManagerDelegate {
    private var central: CBCentralManager!
    unowned let session: Session
    private(set) var discovered: [UUID: DiscoveredDevice] = [:]
    private(set) var handlers: [UUID: DeviceHandler] = [:]
    private var desired: [UUID: DeviceRole] = [:]
    private var connecting: Set<UUID> = []
    var onChange: (() -> Void)?

    var isPoweredOn: Bool { central.state == .poweredOn }

    init(session: Session) {
        self.session = session
        super.init()
        central = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: true])
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Log.info("Bluetooth state: \(central.state.rawValue)")
        session.state.bluetoothOn = central.state == .poweredOn
        if central.state == .poweredOn {
            startScanning()
            reconnectRemembered()
        } else {
            for (id, h) in handlers { h.didDisconnect(); session.handlerDisconnected(h, id: id) }
            handlers.removeAll()
            connecting.removeAll()
        }
    }

    func startScanning() {
        guard central.state == .poweredOn else { return }
        let services = [GATT.ftms, GATT.cyclingPower, GATT.heartRate, GATT.csc, ZwiftUUID.service, ZwiftUUID.serviceFC82]
        central.scanForPeripherals(withServices: services, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        Log.info("Scanning for sensors")
    }

    func stopScanning() { central.stopScan() }

    /// Diagnostic: unfiltered scan that logs every advertiser, then returns to the normal filtered scan.
    func scanAll(seconds: TimeInterval) {
        guard central.state == .poweredOn else { return }
        central.stopScan()
        scanAllUntil = Date().addingTimeInterval(seconds)
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        Log.info("Scan-all for \(Int(seconds)) s")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self else { return }
            self.scanAllUntil = nil
            Log.info("Scan-all done")
            self.central.stopScan()
            self.startScanning()
        }
    }

    private var scanAllUntil: Date?
    private var scanAllLogged: Set<UUID> = []

    private func reconnectRemembered() {
        let s = session.settings
        guard s.autoConnect else { return }
        var wanted: [(String, DeviceRole)] = []
        if let t = s.rememberedTrainer { wanted.append((t, .trainer)) }
        if let h = s.rememberedHeartRate { wanted.append((h, .heartRate)) }
        if let p = s.rememberedPowerMeter { wanted.append((p, .powerMeter)) }
        for c in s.rememberedControllers { wanted.append((c, .controller)) }
        let ids = wanted.compactMap { UUID(uuidString: $0.0) }
        let known = central.retrievePeripherals(withIdentifiers: ids)
        for p in known {
            guard let role = wanted.first(where: { $0.0 == p.identifier.uuidString })?.1 else { continue }
            if discovered[p.identifier] == nil {
                discovered[p.identifier] = DiscoveredDevice(peripheral: p, name: p.name ?? "Remembered device", rssi: 0, services: [], zwiftType: nil, lastSeen: .distantPast)
                Log.info("Reconnecting remembered \(p.name ?? "device") [\(p.identifier.uuidString)] as \(role.label)")
            }
            connect(id: p.identifier, role: role, remember: false)
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let adName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = adName ?? peripheral.name ?? discovered[peripheral.identifier]?.name ?? "Unknown"
        var services = discovered[peripheral.identifier]?.services ?? []
        for u in advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [] { services.insert(u) }
        for u in advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? [] { services.insert(u) }
        let zType = ZwiftDeviceType.from(manufacturerData: advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data)
            ?? discovered[peripheral.identifier]?.zwiftType
        let isNew = discovered[peripheral.identifier] == nil
        discovered[peripheral.identifier] = DiscoveredDevice(peripheral: peripheral, name: name, rssi: RSSI.intValue,
                                                             services: services, zwiftType: zType, lastSeen: Date())
        if scanAllUntil != nil, !scanAllLogged.contains(peripheral.identifier) || (adName != nil && isNew) {
            scanAllLogged.insert(peripheral.identifier)
            let md = (advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data)?.hexString ?? "-"
            let sd = (advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data])?.map { "\($0.key.uuidString)=\($0.value.hexString)" }.joined(separator: ",") ?? "-"
            let conn = (advertisementData[CBAdvertisementDataIsConnectable] as? Bool).map { $0 ? "yes" : "no" } ?? "?"
            Log.info("ScanAll \(name) [\(peripheral.identifier.uuidString)] rssi=\(RSSI) services=\(services.map(\.uuidString).sorted()) mfg=\(md) sdata=\(sd) connectable=\(conn)")
        }
        if isNew {
            let md = (advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data)?.hexString ?? "-"
            Log.info("Found \(name) [\(peripheral.identifier.uuidString)] rssi=\(RSSI) services=\(services.map(\.uuidString).sorted()) mfg=\(md) zwift=\(zType?.label ?? "-")")
            autoConnectIfRemembered(peripheral.identifier)
            autoAdopt(peripheral.identifier)
            onChange?()
        }
    }

    private func autoConnectIfRemembered(_ id: UUID) {
        let s = session.settings
        guard s.autoConnect, handlers[id] == nil, !connecting.contains(id) else { return }
        let str = id.uuidString
        if s.rememberedTrainer == str { connect(id: id, role: .trainer, remember: false) }
        else if s.rememberedHeartRate == str { connect(id: id, role: .heartRate, remember: false) }
        else if s.rememberedPowerMeter == str { connect(id: id, role: .powerMeter, remember: false) }
        else if s.rememberedControllers.contains(str) { connect(id: id, role: .controller, remember: false) }
    }

    // First run convenience: with nothing remembered for a role, adopt the first matching device.
    private func autoAdopt(_ id: UUID) {
        let s = session.settings
        guard s.autoConnect, handlers[id] == nil, let dev = discovered[id] else { return }
        let roles = dev.roles
        if roles.contains(.controller) {
            if !s.rememberedControllers.contains(id.uuidString) { connect(id: id, role: .controller) }
            return
        }
        if roles.contains(.trainer), dev.services.contains(GATT.ftms), s.rememberedTrainer == nil {
            connect(id: id, role: .trainer); return
        }
        if roles.contains(.heartRate), s.rememberedHeartRate == nil {
            connect(id: id, role: .heartRate); return
        }
        if roles.contains(.powerMeter), !dev.services.contains(GATT.ftms), s.rememberedPowerMeter == nil {
            connect(id: id, role: .powerMeter); return
        }
    }

    func connect(id: UUID, role: DeviceRole, remember: Bool = true) {
        guard let dev = discovered[id] else { return }
        if let existing = handlers[id], existing.role == role { return }
        if handlers[id] != nil { disconnect(id: id, forget: false) }
        desired[id] = role
        let handler: DeviceHandler
        switch role {
        case .trainer: handler = TrainerDevice(peripheral: dev.peripheral, session: session)
        case .heartRate: handler = HeartRateDevice(peripheral: dev.peripheral, session: session)
        case .powerMeter: handler = PowerMeterDevice(peripheral: dev.peripheral, session: session)
        case .controller:
            let stored = session.settings.controllerTypes[id.uuidString].flatMap { ZwiftDeviceType(rawValue: UInt8(clamping: $0)) }
            handler = ZwiftControllerDevice(peripheral: dev.peripheral, type: dev.zwiftType ?? stored, name: dev.name, session: session)
        }
        handlers[id] = handler
        connecting.insert(id)
        session.handlerCreated(handler, id: id, name: dev.name)
        if remember { session.remember(id: id, role: role) }
        Log.info("Connecting to \(dev.name) as \(role.label)")
        central.connect(dev.peripheral, options: nil)
        onChange?()
    }

    func disconnect(id: UUID, forget: Bool) {
        desired[id] = nil
        connecting.remove(id)
        if forget { session.forget(id: id) }
        if let h = handlers[id] {
            central.cancelPeripheralConnection(h.peripheral)
            h.didDisconnect()
            handlers[id] = nil
            session.handlerDisconnected(h, id: id)
        }
        onChange?()
    }

    func handler(for id: UUID) -> DeviceHandler? { handlers[id] }
    func isDesired(_ id: UUID) -> Bool { desired[id] != nil }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connecting.remove(peripheral.identifier)
        guard let h = handlers[peripheral.identifier] else { return }
        Log.info("Connected \(peripheral.name ?? peripheral.identifier.uuidString)")
        session.handlerConnected(h, id: peripheral.identifier)
        h.didConnect()
        onChange?()
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connecting.remove(peripheral.identifier)
        Log.warn("Failed to connect \(peripheral.name ?? "?"): \(error?.localizedDescription ?? "unknown")")
        retry(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        connecting.remove(peripheral.identifier)
        Log.info("Disconnected \(peripheral.name ?? "?") \(error.map { "(\($0.localizedDescription))" } ?? "")")
        if let h = handlers[peripheral.identifier] {
            h.didDisconnect()
            session.handlerDropped(h, id: peripheral.identifier)
        }
        retry(peripheral)
        onChange?()
    }

    private func retry(_ peripheral: CBPeripheral) {
        guard desired[peripheral.identifier] != nil, handlers[peripheral.identifier] != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.desired[peripheral.identifier] != nil, self.central.state == .poweredOn else { return }
            self.connecting.insert(peripheral.identifier)
            self.central.connect(peripheral, options: nil)
        }
    }
}
