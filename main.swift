// Quando la tastiera Lenovo esterna è collegata:
//   - layout "Italiano – Pro"
//   - tasti come su Windows (solo sulla Lenovo):
//       Ctrl    -> Command  (Ctrl+C/V/Z...)
//       Alt     -> Command  (Alt+Tab)
//       Windows -> Ctrl
//       AltGr resta Option (@ # [ ])
// Quando viene scollegata: torna al layout "ABC".
import Foundation
import IOKit
import Carbon

let vendorID = 1203      // 0x04B3 (IBM/Lenovo)
let productID = 12325    // 0x3025
let layoutEsterna = "com.apple.keylayout.Italian-Pro"
let layoutInterna = "com.apple.keylayout.ABC"
let leftCtrl = 0x7000000E0, leftAlt = 0x7000000E2, leftGUI = 0x7000000E3
let rightCtrl = 0x7000000E4, rightGUI = 0x7000000E7
let remaps = [(leftCtrl, leftGUI), (leftAlt, leftGUI), (leftGUI, leftCtrl), (rightCtrl, rightGUI)]
let mapping = "{\"UserKeyMapping\":[" + remaps.map {
    "{\"HIDKeyboardModifierMappingSrc\":\($0.0),\"HIDKeyboardModifierMappingDst\":\($0.1)}"
}.joined(separator: ",") + "]}"

func log(_ s: String) { print("\(Date()) \(s)"); fflush(stdout) }

func matchingDict() -> CFMutableDictionary {
    let d = IOServiceMatching("IOHIDDevice")! as NSMutableDictionary
    d["IOPropertyMatch"] = ["VendorID": vendorID, "ProductID": productID]
    return d
}

func isPresent() -> Bool {
    var iter: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, matchingDict(), &iter) == KERN_SUCCESS else { return false }
    defer { IOObjectRelease(iter) }
    var found = false
    while case let s = IOIteratorNext(iter), s != 0 { found = true; IOObjectRelease(s) }
    return found
}

func selectLayout(_ id: String) {
    let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
    guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource],
          let src = list.first else { log("layout non trovato (è abilitato?): \(id)"); return }
    let err = TISSelectInputSource(src)
    log("layout -> \(id) (\(err))")
}

func applyMapping() {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
    p.arguments = ["property", "--matching", "{\"VendorID\":\(vendorID),\"ProductID\":\(productID)}", "--set", mapping]
    p.standardOutput = FileHandle.nullDevice
    do { try p.run(); p.waitUntilExit(); log("mappatura tasti applicata (\(p.terminationStatus))") }
    catch { log("hidutil fallito: \(error)") }
}

var lastState: Bool? = nil
func refresh() {
    let present = isPresent()
    if present { applyMapping() }
    if present != lastState {
        selectLayout(present ? layoutEsterna : layoutInterna)
        lastState = present
    }
}

var pending: DispatchWorkItem?
func scheduleRefresh() {
    pending?.cancel()
    let w = DispatchWorkItem { refresh() }
    pending = w
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: w)
}

func drain(_ iter: io_iterator_t) { while case let s = IOIteratorNext(iter), s != 0 { IOObjectRelease(s) } }

let port = IONotificationPortCreate(kIOMainPortDefault)
CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .defaultMode)
let callback: IOServiceMatchingCallback = { _, iter in drain(iter); scheduleRefresh() }
var addedIter: io_iterator_t = 0, removedIter: io_iterator_t = 0
IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, matchingDict(), callback, nil, &addedIter)
drain(addedIter)
IOServiceAddMatchingNotification(port, kIOTerminatedNotification, matchingDict(), callback, nil, &removedIter)
drain(removedIter)

log("avviato")
refresh()
CFRunLoopRun()
