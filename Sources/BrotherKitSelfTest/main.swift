import Foundation
import BrotherKit

var failures = 0
func check(_ cond: Bool, _ msg: String, line: Int = #line) {
    if cond { print("✓ \(msg)") } else { print("✗ \(msg) (řádek \(line))"); failures += 1 }
}

// Kódování textu jako UWSWTranslate
check(BrCodec.encode("Wifi") == "57-69-66-69", "SSID se kóduje do hex s pomlčkami")
check(BrCodec.encode("A") == "0x41", "jednobajtová hodnota dostane prefix 0x")
check(BrCodec.encode("Č") == "c4-8c", "UTF‑8 diakritika")
check(BrCodec.decode("57-69-66-69") == "Wifi", "dekódování textu")
check(BrCodec.decode("C0-A8-01-0A", as: .ipv4) == "192.168.1.10", "dekódování IP")
check(BrCodec.encodeIPv4("192.168.1.10") == "C0-A8-01-0A", "kódování IP")
check(BrCodec.decode("68-94-23-45-0D-1F", as: .mac) == "68:94:23:45:0D:1F", "dekódování MAC")
check(BrCodec.decode("Moje-Sit") == "Moje-Sit", "běžný text se nemění")

// Dlouhé heslo se dělí na .0 / .1
let long = String(repeating: "a", count: 40)
let split = BrCodec.pairsForLong(id: "459288", text: long)
check(split.count == 2 && split[0].0 == "459288.0" && split[1].0 == "459288.1", "heslo > 32 B se dělí na dvě části")
check(split[0].1.hasSuffix("=") && split[1].1.hasPrefix("=-"), "značky pokračování = a =-")
check(BrCodec.pairsForLong(id: "459288", text: "heslo123").count == 1, "krátké heslo zůstane celé")

// Příkazy pro jednoduchý režim
let cfg = WiFiConfig(ssid: "Domov", key: "tajneheslo")
let pairs = BrWiFiCommands.pairs(for: cfg)
let cmds = BrWiFiCommands.commands(pairs)
check(cmds.first == "@PJL DEFAULT OBJBRNET=\"458867:0\"", "první je reset stavu 458867:0")
check(cmds.last == "@PJL DEFAULT OBJBRNET=\"458865:5\"", "poslední je potvrzení 458865:5 (jednoduchý režim)")
check(cmds.contains("@PJL DEFAULT OBJBRNET=\"458877:44-6f-6d-6f-76\""), "SSID v příkazu")
check(cmds.contains("@PJL DEFAULT OBJBRNET=\"458970.2:0\""), "DHCP")
check(!BrWiFiCommands.redacted(pairs).joined().contains(BrCodec.encode("tajneheslo")), "heslo se nezapisuje do logu")
let job = String(decoding: PJL.job(["@PJL INFO ID"]), as: UTF8.self)
check(job == "\u{1B}%-12345X@PJL\r\n@PJL INFO ID\r\n\u{1B}%-12345X", "rámování PJL úlohy shodné s originálem")

// WPA ruční režim
let wpa = BrWiFiCommands.pairs(for: WiFiConfig(ssid: "X1", key: "12345678", security: .wpaPersonalAES))
check(wpa.contains { $0 == ("458881", "3") } && wpa.contains { $0 == ("458880", "4") }, "WPA2 AES: auth 3, enc 4")
check(wpa.last! == ("458865", "1"), "ruční režim potvrzuje 458865:1")
let mixedTKIP = BrWiFiCommands.pairs(for: WiFiConfig(ssid: "X1", key: "12345678", security: .wpaPersonalMixed), encryptionOverride: 3)
check(mixedTKIP.contains { $0 == ("458880", "3") }, "záložní pokus s TKIP")

// Validace
check(!WiFiConfig(ssid: "", key: "x").validate().isEmpty, "prázdné SSID je chyba")
check(!WiFiConfig(ssid: "A", key: "1234567").validate().isEmpty, "krátké heslo je chyba")
check(WiFiConfig(ssid: "A", key: "12345678").validate().isEmpty, "platná konfigurace")

// Odpověď na INQUIRE
let inq = "@PJL INQUIRE OBJBRNET\r\nOBJBRNET=\"458867:1\"\r\n\u{0C}"
check(BrWiFiCommands.parseInquire(inq, id: "458867") == "1", "čtení hodnoty z INQUIRE")

// Skenování – formát podle setDummyData originálu
let scan = """
3
LDEV,458842,458843,Auth,459333
VDEV,FF,1;3;4-8;11;12,FFFFF,1
LAP,458848.*,458849.*,458850.*,458851.*,458852.*,458853.*,458854.*
VAP,Domácí síť$, 2.4,5,1,6,3,3,4
VAP,Kavárna,5,1,11,1,1,1
"""
let (status, result) = BrScanParser.parse(scan)
check(status == 3, "stav skenu")
check(result.networks.count == 2, "dvě sítě")
check(result.networks.first?.ssid == "Domácí síť, 2.4", "escapovaná čárka v SSID")
check(result.networks.first?.channel == 6 && result.networks.first?.security == 3, "kanál a zabezpečení")
check(result.device["458843"] == "1;3;4-8;11;12", "údaje o zařízení")

// Firmware
let fw = FirmwareInfo(lines: ["MODEL=\"HL-L2340D series\"", "SPEC=\"0001\"", "FIRMID=\"MAIN\"", "FIRMVER=\"1.26\"", "FIRMID=\"SUB1\"", "FIRMVER=\"1.05\""])
check(fw.model == "HL-L2340D series" && fw.spec == "0001" && fw.parts.count == 2, "parsování informací o firmwaru")
check(BrotherFirmwareService.parse("<RESPONSEINFO><FIRMUPDATEINFO><VERSIONCHECK>1</VERSIONCHECK></FIRMUPDATEINFO></RESPONSEINFO>").map { if case .upToDate = $0 { return true } else { return false } } == true, "odpověď: aktuální")
if case .update(let v, let u)? = BrotherFirmwareService.parse("<VERSIONCHECK>0</VERSIONCHECK><LATESTVERSION>1.30</LATESTVERSION><FIRMID>MAIN</FIRMID><PATH>https://update-akamai.brother.co.jp/x/LZ1234_A.djf</PATH>") {
    check(v == "1.30" && BrotherFirmwareService.isTrusted(u), "odpověď: aktualizace k dispozici")
} else { check(false, "odpověď: aktualizace k dispozici") }
check(!BrotherFirmwareService.isTrusted(URL(string: "https://evil.example/brother.co.jp.djf")!), "cizí doména se odmítne")

let idSplit = PrinterStatus.splitID("Brother HL-L2340D series:84U-F56:Ver.1.30")
check(idSplit.model == "Brother HL-L2340D series" && idSplit.version == "1.30", "rozdělení INFO ID na model a verzi")
let body = String(BrotherFirmwareService.requestBodyForTest(info: fw, partID: "MAIN"))
check(body.contains("<INSPECTMODE>0</INSPECTMODE>") && body.contains("<DRIVER>EWS</DRIVER>") && !body.contains("SERIAL"), "dotaz na firmware v ověřeném tvaru")

check(BrotherPrinter.displayText("Ahoj Jiří, tiskni prosím") == "Ahoj Jiri, tiskn", "text displeje: bez diakritiky, max. 16 znaků")

// SNMP BER
let req = SNMP.request(community: "public", requestID: 1234, oid: SNMP.parseOID("1.3.6.1.4.1.2435.2.4.3.99.3.1.6.1.2"))
check(req.first == 0x30 && req.count > 30, "SNMP požadavek")

print(failures == 0 ? "\nVšechny testy prošly." : "\nSelhalo: \(failures)")
exit(failures == 0 ? 0 : 1)
