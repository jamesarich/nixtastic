// Answers two questions about L2CAP CoC as a cross-platform client-to-client bearer:
//   1. does an insecure channel complete Apple <-> Android with NO pairing prompt
//   2. how a central learns the dynamic PSM
// CoreBluetooth is the same framework on macOS and iOS, and publishL2CAPChannel needs no
// entitlement, so the Mac stands in for the iPad here and needs no signed app.
// Build: env -u DEVELOPER_DIR -u SDKROOT -u CC -u CXX -u NIX_CC \
//          PATH="/usr/bin:/bin" swiftc -O l2cap-peripheral.swift -o l2cap-peripheral
import Foundation
import CoreBluetooth

// A custom 128-bit service, plus one characteristic whose value is the PSM as a little-endian
// UInt16. This is the answer to question 2: the PSM is dynamic and assigned at publish time, and
// iOS cannot put arbitrary data in an advertisement, so a GATT read is the only portable channel
// for it.
let serviceUUID = CBUUID(string: "6E4D0001-B5A3-F393-E0A9-E50E24DCCA9E")
let psmUUID     = CBUUID(string: "6E4D0002-B5A3-F393-E0A9-E50E24DCCA9E")

func log(_ s: String) {
    let t = ISO8601DateFormatter().string(from: Date())
    print("[\(t)] \(s)")
    fflush(stdout)
}

final class Peripheral: NSObject, CBPeripheralManagerDelegate, StreamDelegate {
    var manager: CBPeripheralManager!
    var psmCharacteristic: CBMutableCharacteristic!
    var psm: CBL2CAPPSM = 0
    var channels: [CBL2CAPChannel] = []
    var rxTotal = 0

    func start() {
        manager = CBPeripheralManager(delegate: self, queue: nil)
    }

    func peripheralManagerDidUpdateState(_ p: CBPeripheralManager) {
        log("state=\(p.state.rawValue) (5 == poweredOn)")
        guard p.state == .poweredOn else { return }
        // withEncryption: false is the whole point. An encrypted channel forces LE Security Mode 1
        // Level 3, which means pairing and a prompt on both platforms.
        p.publishL2CAPChannel(withEncryption: false)
    }

    func peripheralManager(_ p: CBPeripheralManager, didPublishL2CAPChannel PSM: CBL2CAPPSM, error: Error?) {
        if let e = error { log("PUBLISH FAILED: \(e)"); return }
        psm = PSM
        log("published insecure L2CAP channel, PSM=\(PSM) (0x\(String(PSM, radix: 16)))")

        var le = PSM.littleEndian
        let bytes = withUnsafeBytes(of: &le) { Data($0) }
        psmCharacteristic = CBMutableCharacteristic(type: psmUUID,
                                                   properties: [.read],
                                                   value: bytes,
                                                   permissions: [.readable])
        let service = CBMutableService(type: serviceUUID, primary: true)
        service.characteristics = [psmCharacteristic]
        p.add(service)
    }

    func peripheralManager(_ p: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let e = error { log("ADD SERVICE FAILED: \(e)"); return }
        log("service added, advertising as l2cap-probe")
        p.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [serviceUUID],
                            CBAdvertisementDataLocalNameKey: "l2cap-probe"])
    }

    func peripheralManagerDidStartAdvertising(_ p: CBPeripheralManager, error: Error?) {
        if let e = error { log("ADVERTISE FAILED: \(e)") } else { log("advertising") }
    }

    func peripheralManager(_ p: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        log("GATT read of the PSM characteristic from \(request.central.identifier)")
        request.value = psmCharacteristic.value
        p.respond(to: request, withResult: .success)
    }

    func peripheralManager(_ p: CBPeripheralManager, didOpen channel: CBL2CAPChannel?, error: Error?) {
        if let e = error { log("CHANNEL OPEN FAILED: \(e)"); return }
        guard let c = channel else { return }
        channels.append(c)
        log("L2CAP CHANNEL OPEN from \(c.peer.identifier), psm=\(c.psm)")
        for s in [c.inputStream, c.outputStream] as [Stream] {
            s.delegate = self
            s.schedule(in: .main, forMode: .default)
            s.open()
        }
    }

    // Echo whatever arrives, so the Android side can prove a round trip rather than just a connect.
    func stream(_ stream: Stream, handle event: Stream.Event) {
        guard event == .hasBytesAvailable, let input = stream as? InputStream else { return }
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = input.read(&buf, maxLength: buf.count)
        guard n > 0 else { return }
        rxTotal += n
        let text = String(bytes: buf[0..<min(n, 64)], encoding: .utf8) ?? "<binary>"
        log("rx \(n) B (total \(rxTotal)): \(text)")
        if let out = channels.last?.outputStream, out.hasSpaceAvailable {
            let reply = Array("echo:".utf8) + buf[0..<n]
            _ = reply.withUnsafeBufferPointer { out.write($0.baseAddress!, maxLength: reply.count) }
            log("echoed \(reply.count) B")
        }
    }
}

let peripheral = Peripheral()
peripheral.start()
log("running - ctrl-c to stop")
RunLoop.main.run()
