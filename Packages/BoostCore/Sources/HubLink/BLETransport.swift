#if canImport(CoreBluetooth)
import CoreBluetooth
import Foundation

/// Transport Bluetooth Low Energy : scan, connexion, reconnexion automatique.
///
/// Tout l'état est manipulé sur `queue`, la file série passée à CoreBluetooth.
public final class BLETransport: NSObject, HubTransport, @unchecked Sendable {
    public let events: AsyncStream<TransportEvent>
    private let continuation: AsyncStream<TransportEvent>.Continuation

    private let queue = DispatchQueue(label: "hublink.ble")
    private let serviceUUID = CBUUID(string: LWP.serviceUUID)
    private let characteristicUUID = CBUUID(string: LWP.characteristicUUID)

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var characteristic: CBCharacteristic?
    private var wantsConnection = false

    public override init() {
        (events, continuation) = AsyncStream<TransportEvent>.makeStream()
        super.init()
    }

    // MARK: - HubTransport

    public func start() {
        queue.async {
            self.wantsConnection = true
            if let central = self.central {
                self.proceed(with: central)
            } else {
                // La création déclenche centralManagerDidUpdateState.
                self.central = CBCentralManager(delegate: self, queue: self.queue)
            }
        }
    }

    public func stop() {
        queue.async {
            self.wantsConnection = false
            self.central?.stopScan()
            if let peripheral = self.peripheral {
                self.central?.cancelPeripheralConnection(peripheral)
            }
            self.peripheral = nil
            self.characteristic = nil
            self.emit(.idle)
        }
    }

    public func send(_ data: Data) {
        queue.async {
            guard let peripheral = self.peripheral, let characteristic = self.characteristic,
                  peripheral.state == .connected else { return }
            // La doc annonce « write without response » mais précise que l'écriture
            // se fait avec réponse tant que le contrôle de flux n'est pas implémenté.
            let type: CBCharacteristicWriteType = characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
            peripheral.writeValue(data, for: characteristic, type: type)
        }
    }

    // MARK: - Interne

    private func emit(_ state: TransportState) {
        continuation.yield(.state(state))
    }

    /// Lance le scan ou la reconnexion selon l'état du Bluetooth.
    private func proceed(with central: CBCentralManager) {
        guard wantsConnection else { return }
        switch central.state {
        case .poweredOn:
            if let peripheral {
                if peripheral.state == .connected, characteristic != nil { return }
                emit(.reconnecting)
                central.connect(peripheral, options: nil)
            } else {
                emit(.scanning)
                central.scanForPeripherals(withServices: [serviceUUID], options: nil)
            }
        case .poweredOff:
            emit(.unavailable(reason: "Le Bluetooth est désactivé."))
        case .unauthorized:
            emit(.unavailable(reason: "L'accès au Bluetooth n'est pas autorisé pour cette app."))
        case .unsupported:
            emit(.unavailable(reason: "Cet appareil ne prend pas en charge le Bluetooth Low Energy."))
        case .resetting, .unknown:
            break
        @unknown default:
            break
        }
    }

    /// Vrai si la publicité vient du hub visé (doc §2 : octet « System Type »).
    private func isTargetHub(_ advertisementData: [String: Any]) -> Bool {
        guard let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data, data.count >= 4 else {
            // Sans données fabricant, le filtre sur le service suffit.
            return true
        }
        let bytes = [UInt8](data)
        let manufacturer = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
        guard manufacturer == LWP.manufacturerID else { return false }
        // Après l'identifiant fabricant : état du bouton, puis type de système.
        return bytes[3] == LWP.moveHubSystemType
    }
}

// MARK: - CBCentralManagerDelegate

extension BLETransport: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state != .poweredOn {
            characteristic = nil
        }
        proceed(with: central)
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard wantsConnection, self.peripheral == nil, isTargetHub(advertisementData) else { return }
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        emit(.connecting)
        central.connect(peripheral, options: nil)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([serviceUUID])
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral === self.peripheral else { return }
        // On repart d'un scan : le hub a peut-être changé d'identifiant.
        self.peripheral = nil
        characteristic = nil
        proceed(with: central)
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral === self.peripheral else { return }
        characteristic = nil
        if wantsConnection {
            // Demande en attente, sans expiration : aboutit dès que le hub est rallumé.
            emit(.reconnecting)
            central.connect(peripheral, options: nil)
        } else {
            self.peripheral = nil
            emit(.idle)
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BLETransport: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.discoverCharacteristics([characteristicUUID], for: service)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let found = service.characteristics?.first(where: { $0.uuid == characteristicUUID }) else {
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.setNotifyValue(true, for: found)
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == characteristicUUID, characteristic.isNotifying else {
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        self.characteristic = characteristic
        emit(.connected(name: peripheral.name ?? "Hub"))
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == characteristicUUID, let value = characteristic.value else { return }
        continuation.yield(.data(value))
    }
}
#endif
