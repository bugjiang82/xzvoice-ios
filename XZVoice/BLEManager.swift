import Foundation
import CoreBluetooth
import Combine

/// CoreBluetooth central for the XZ-Voice board (Nordic UART Service).
/// Protocol (board side: firmware/ble_nus.py):
///   notify:  [type][payload]  type: 1=audio, 3=text-framed, 4=pcm, 5=status-framed
///   framed:  [len16le][utf8...] (may span multiple notifications)
///   write:   [0x02][cmd] or plain ASCII
final class BLEManager: NSObject, ObservableObject {
    static let nusService = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    static let rxUUID = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
    static let txUUID = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")

    @Published var bluetoothOn = false
    @Published var connected = false
    @Published var deviceName = ""
    @Published var mtu = 23
    @Published var throughput = 0.0          // bytes/s (audio payload)
    @Published var totalAudioBytes = 0
    @Published var log: [String] = []
    @Published var segments: [Segment] = []
    @Published var scanning = false

    struct Segment: Identifiable {
        let no: Int
        let totalADPCM: Int
        var received: Int = 0
        var pcmBytes: Int = 0
        var fileURL: URL?
        var date = Date()
        var done: Bool { fileURL != nil }
    }

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var rxChar: CBCharacteristic?
    private var txChar: CBCharacteristic?

    // reassembly state
    private var textBuf = Data()
    private var segNo = -1
    private var segTotal = 0
    private var segData = Data()
    private var decoder = ADPCM.Decoder()

    // throughput window
    private var window: [(t: Date, n: Int)] = []

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    // MARK: public API

    func startScan() {
        guard central.state == .poweredOn else { return }
        scanning = true
        addLog("扫描中...")
        central.scanForPeripherals(withServices: [Self.nusService], options: nil)
        // fallback: also match by name if service-filter scan finds nothing
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, !self.connected, self.scanning else { return }
            self.addLog("未按服务过滤到，改为全量扫描...")
            self.central.stopScan()
            self.central.scanForPeripherals(withServices: nil, options: nil)
        }
    }

    func stopScan() {
        central.stopScan()
        scanning = false
    }

    func disconnect() {
        if let p = peripheral {
            central.cancelPeripheralConnection(p)
        }
    }

    func send(_ cmd: String) {
        guard let rx = rxChar, let p = peripheral else {
            addLog("未连接，无法发送 \(cmd)")
            return
        }
        var d = Data([0x02])
        d.append(cmd.data(using: .utf8) ?? Data())
        p.writeValue(d, for: rx, type: .withoutResponse)
        addLog("→ \(cmd)")
    }

    func startRecording(seconds: Int? = nil) {
        send(seconds == nil ? "START" : "REC:\(seconds!)")
    }

    func stopRecording() {
        send("STOP")
    }

    private func addLog(_ s: String) {
        DispatchQueue.main.async {
            let fmt = DateFormatter()
            fmt.dateFormat = "HH:mm:ss"
            self.log.append("\(fmt.string(from: Date())) \(s)")
            if self.log.count > 200 {
                self.log.removeFirst(self.log.count - 200)
            }
        }
    }

    // MARK: protocol handling

    private func handleNotify(_ data: Data) {
        guard let type = data.first else { return }
        let payload = data.dropFirst()
        switch type {
        case 1: // audio
            let n = payload.count
            totalAudioBytes += n
            window.append((Date(), n))
            if segNo >= 0 {
                segData.append(payload)
                markSegmentReceived(n)
                if segData.count >= segTotal {
                    finishSegment()
                }
            }
        case 3, 5: // framed text / status
            textBuf.append(payload)
            tryEmitFramedText()
        case 4: // TTS PCM (future)
            break
        default:
            addLog("? type=\(type) \(payload.prefix(16).map { String(format: "%02x", $0) }.joined())")
        }
    }

    private func tryEmitFramedText() {
        while textBuf.count >= 2 {
            let ln = Int(textBuf[0]) | (Int(textBuf[1]) << 8)
            guard textBuf.count >= 2 + ln else { return }
            let body = textBuf.subdata(in: 2..<(2 + ln))
            textBuf.removeFirst(2 + ln)
            if let s = String(data: body, encoding: .utf8) {
                handleText(s)
            }
        }
    }

    private func handleText(_ s: String) {
        if s.hasPrefix("SEG:") {
            let parts = s.split(separator: ":")
            if parts.count == 3, let no = Int(parts[1]), let total = Int(parts[2]) {
                segNo = no
                segTotal = total
                segData = Data()
                decoder.reset()
                DispatchQueue.main.async {
                    self.segments.append(Segment(no: no, totalADPCM: total))
                }
                addLog("段 #\(no) 开始 (\(total)B)")
            }
        } else {
            addLog("板子: \(s)")
        }
    }

    private func markSegmentReceived(_ n: Int) {
        DispatchQueue.main.async {
            if let idx = self.segments.lastIndex(where: { $0.no == self.segNo }) {
                self.segments[idx].received += n
            }
        }
    }

    private func finishSegment() {
        let no = segNo
        let pcm = decoder.decode(segData)
        let wav = ADPCM.wavFile(pcm: pcm)
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = dir.appendingPathComponent(String(format: "seg_%04d.wav", no))
        try? wav.write(to: url)
        let secs = Double(pcm.count) / 2 / 16000
        addLog(String(format: "段 #%d 完成: %.1fs → %@", no, secs, url.lastPathComponent))
        DispatchQueue.main.async {
            if let idx = self.segments.lastIndex(where: { $0.no == no }) {
                self.segments[idx].pcmBytes = pcm.count
                self.segments[idx].fileURL = url
            }
        }
        segNo = -1
        segTotal = 0
        segData = Data()
    }

    private func updateThroughput() {
        let cutoff = Date().addingTimeInterval(-3)
        window.removeAll { $0.t < cutoff }
        guard let first = window.first?.t, window.count > 1 else {
            throughput = 0
            return
        }
        let elapsed = Date().timeIntervalSince(first)
        let bytes = window.reduce(0) { $0 + $1.n }
        throughput = elapsed > 0 ? Double(bytes) / elapsed : 0
    }

    /// Rolling throughput timer
    private lazy var ticker: Timer = {
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.updateThroughput()
        }
    }()

    func activateTicker() { _ = ticker }
}

// MARK: - CBCentralManagerDelegate

extension BLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        bluetoothOn = central.state == .poweredOn
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        let isBoard = name.hasPrefix("XZ-Voice") || name.hasPrefix("MPY")
        guard isBoard else { return }
        addLog("发现设备: \(name) RSSI \(RSSI)")
        stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connected = true
        deviceName = peripheral.name ?? "MPY ESP32"
        addLog("已连接 \(deviceName)，发现服务...")
        peripheral.discoverServices([Self.nusService])
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        connected = false
        rxChar = nil
        txChar = nil
        addLog("已断开")
    }
}

// MARK: - CBPeripheralDelegate

extension BLEManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let svc = peripheral.services?.first(where: { $0.uuid == Self.nusService }) else {
            addLog("未找到 NUS 服务")
            return
        }
        peripheral.discoverCharacteristics([Self.rxUUID, Self.txUUID], for: svc)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for c in service.characteristics ?? [] {
            if c.uuid == Self.txUUID {
                txChar = c
                peripheral.setNotifyValue(true, for: c)
                addLog("订阅 TX 通知")
            } else if c.uuid == Self.rxUUID {
                rxChar = c
                addLog("RX 就绪")
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if error == nil {
            addLog("通知已开启，等待数据...")
            activateTicker()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value, !data.isEmpty else { return }
        handleNotify(data)
    }
}
