import SwiftUI
import UIKit
import RoomPlan
import CoreBluetooth
import simd

enum CallbackCodec {
    static func b64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func open(_ base: URL, fragment: String) {
        guard var p = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return }
        p.fragment = fragment
        guard let u = p.url else { return }
        DispatchQueue.main.async { UIApplication.shared.open(u) }
    }
    static func lidar(_ payload: [String:Any], to url: URL) {
        guard JSONSerialization.isValidJSONObject(payload), let d = try? JSONSerialization.data(withJSONObject: payload) else { return }
        open(url, fragment: "zp_lidar=" + b64url(d))
    }
    static func bosch(_ mm: Int, to url: URL) { open(url, fragment: "zp_bosch=\(mm)") }
    static func error(_ text: String, to url: URL) { open(url, fragment: "zp_error=" + b64url(Data(text.utf8))) }
}

@MainActor final class BridgeRouter: ObservableObject {
    enum Action { case idle, lidar(URL), bosch(URL) }
    @Published var action: Action = .idle
    @Published var status = "Откройте Замер+ в Safari и нажмите LiDAR или Bosch."
    func handle(_ url: URL) {
        guard url.scheme?.lowercased() == "zamerplusbridge" else { return }
        let host = (url.host ?? "").lowercased()
        let c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        guard let s = c?.queryItems?.first(where:{$0.name=="return"})?.value,
              let back = URL(string:s), back.scheme=="https" else {
            status = "Некорректный адрес возврата"; return
        }
        if host=="lidar" { action = .lidar(back) }
        else if host=="bosch" { action = .bosch(back) }
        else { status = "Неизвестная команда Safari" }
    }
}

enum BridgeSheet: Identifiable {
    case lidar(URL), bosch(URL)
    var id: String { switch self { case .lidar(let u): return "l-"+u.absoluteString; case .bosch(let u): return "b-"+u.absoluteString } }
}

@main struct ZamerPlusBridgeApp: App {
    @StateObject private var router = BridgeRouter()
    var body: some Scene {
        WindowGroup {
            BridgeHome().environmentObject(router).onOpenURL { router.handle($0) }
        }
    }
}

struct BridgeHome: View {
    @EnvironmentObject var router: BridgeRouter
    var sheet: Binding<BridgeSheet?> { Binding(
        get: {
            switch router.action {
            case .idle: return nil
            case .lidar(let u): return .lidar(u)
            case .bosch(let u): return .bosch(u)
            }
        },
        set: { if $0 == nil { router.action = .idle } }
    )}
    var body: some View {
        NavigationStack {
            VStack(spacing:18) {
                ZStack { RoundedRectangle(cornerRadius:28).fill(.black).frame(width:96,height:96); Text("З+").font(.system(size:38,weight:.black)).foregroundStyle(.white) }
                Text("Замер+ Bridge").font(.largeTitle.bold())
                Text(router.status).multilineTextAlignment(.center).foregroundStyle(.secondary)
                Spacer()
                VStack(alignment:.leading,spacing:10) {
                    Label("LiDAR — Apple RoomPlan",systemImage:"viewfinder")
                    Label("Bosch — CoreBluetooth",systemImage:"dot.radiowaves.left.and.right")
                    Label("Результат возвращается в Safari",systemImage:"safari")
                }.font(.headline).padding().frame(maxWidth:.infinity,alignment:.leading).background(.thinMaterial,in:RoundedRectangle(cornerRadius:20))
            }.padding(24).fullScreenCover(item: sheet) { s in
                switch s {
                case .lidar(let u): RoomScannerScreen(returnURL:u)
                case .bosch(let u): BoschCaptureScreen(returnURL:u)
                }
            }
        }
    }
}

final class RoomScannerVC: UIViewController, RoomCaptureViewDelegate {
    var onResult: ((Result<[String:Any],Error>)->Void)?
    private var capture: RoomCaptureView!
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .black
        capture = RoomCaptureView(frame:view.bounds); capture.autoresizingMask=[.flexibleWidth,.flexibleHeight]; capture.delegate=self; capture.isModelEnabled=true; view.addSubview(capture)
        let b = UIButton(type: .system)
        b.setTitle("Готово", for: .normal)
        b.titleLabel?.font = .boldSystemFont(ofSize: 17)
        b.backgroundColor = .white
        b.setTitleColor(.black, for: .normal)
        b.layer.cornerRadius = 18
        b.translatesAutoresizingMaskIntoConstraints = false
        b.addTarget(self, action: #selector(done), for: .touchUpInside)
        view.addSubview(b)
        NSLayoutConstraint.activate([b.trailingAnchor.constraint(equalTo:view.safeAreaLayoutGuide.trailingAnchor,constant:-16),b.bottomAnchor.constraint(equalTo:view.safeAreaLayoutGuide.bottomAnchor,constant:-16),b.widthAnchor.constraint(equalToConstant:110),b.heightAnchor.constraint(equalToConstant:50)])
    }
    override func viewDidAppear(_ animated:Bool) {
        super.viewDidAppear(animated)
        guard RoomCaptureSession.isSupported else { onResult?(.failure(NSError(domain:"ZamerPlus",code:1,userInfo:[NSLocalizedDescriptionKey:"RoomPlan/LiDAR недоступен"]))); dismiss(animated:true); return }
        capture.captureSession.run(configuration:.init())
    }
    @objc func done(){ capture.captureSession.stop() }
    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool { true }
    func captureView(didPresent room: CapturedRoom, error: Error?) {
        if let e=error { onResult?(.failure(e)); dismiss(animated:true); return }
        let wallMap=Dictionary(uniqueKeysWithValues:room.walls.map{($0.identifier,$0)})
        let walls:[[String:Any]]=room.walls.map{ s in
            let c=s.transform.columns.3, a=s.transform.columns.0
            return ["id":s.identifier.uuidString,"widthMm":Int((s.dimensions.x*1000).rounded()),"heightMm":Int((s.dimensions.y*1000).rounded()),"xMm":Int((c.x*1000).rounded()),"zMm":Int((c.z*1000).rounded()),"headingDeg":Double(atan2(a.z,a.x)*180/Float.pi)]
        }
        func opening(_ s:CapturedRoom.Surface,_ type:String)->[String:Any]{
            let c=s.transform.columns.3; var off:Float=0; var bottom=max(0,c.y-s.dimensions.y/2)
            if let pid=s.parentIdentifier, let w=wallMap[pid] {
                let wc=w.transform.columns.3, ax=SIMD2<Float>(w.transform.columns.0.x,w.transform.columns.0.z), dir=ax/max(simd_length(ax),0.0001), delta=SIMD2<Float>(c.x-wc.x,c.z-wc.z)
                off=simd_dot(delta,dir)+w.dimensions.x/2; bottom=max(0,(c.y-s.dimensions.y/2)-(wc.y-w.dimensions.y/2))
            }
            return ["id":s.identifier.uuidString,"type":type,"parentId":s.parentIdentifier?.uuidString ?? "","widthMm":Int((s.dimensions.x*1000).rounded()),"heightMm":Int((s.dimensions.y*1000).rounded()),"offsetMm":Int((off*1000).rounded()),"bottomMm":Int((bottom*1000).rounded())]
        }
        var ops:[[String:Any]]=[]; ops += room.doors.map{opening($0,"door")}; ops += room.windows.map{opening($0,"window")}; ops += room.openings.map{opening($0,"opening")}
        var poly:[[String:Any]]=[]
        if let f=room.floors.first { for p in f.polygonCorners { let w=f.transform*SIMD4<Float>(p.x,p.y,p.z,1); poly.append(["xMm":Int((w.x*1000).rounded()),"zMm":Int((w.z*1000).rounded())]) } }
        let hs=room.walls.map{Int(($0.dimensions.y*1000).rounded())}.sorted(), h=hs.isEmpty ? 0 : hs[hs.count/2]
        onResult?(.success(["walls":walls,"openings":ops,"floorPolygon":poly,"heightMm":h,"doors":room.doors.count,"windows":room.windows.count,"capturedAt":Int(Date().timeIntervalSince1970*1000)])); dismiss(animated:true)
    }
}

struct RoomScannerScreen: UIViewControllerRepresentable {
    let returnURL: URL
    func makeUIViewController(context:Context)->RoomScannerVC {
        let v=RoomScannerVC(); v.onResult={ r in
            switch r { case .success(let p): CallbackCodec.lidar(p,to:returnURL); case .failure(let e): CallbackCodec.error(e.localizedDescription,to:returnURL) }
        }; return v
    }
    func updateUIViewController(_ uiViewController:RoomScannerVC,context:Context){}
}

final class BoschManager: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published var status="Подготовка Bluetooth…"; @Published var last:Int?
    var onMeasurement:((Int)->Void)?
    private lazy var central=CBCentralManager(delegate:self,queue:.main); private var peripheral:CBPeripheral?
    private let service=CBUUID(string:"02A6C0D0-0451-4000-B000-FB3210111989"), chUUID=CBUUID(string:"02A6C0D1-0451-4000-B000-FB3210111989"), startCmd=Data([0xC0,0x55,0x02,0x01,0x00,0x1A])
    func start(){ _=central; if central.state == .poweredOn { scan() } }
    func stop(){ central.stopScan(); if let p=peripheral { central.cancelPeripheralConnection(p) } }
    func scan(){ status="Ищу Bosch GLM…"; central.scanForPeripherals(withServices:nil,options:[CBCentralManagerScanOptionAllowDuplicatesKey:false]) }
    func centralManagerDidUpdateState(_ c:CBCentralManager){ if c.state == .poweredOn { scan() } else if c.state == .poweredOff { status="Включите Bluetooth" } else if c.state == .unauthorized { status="Разрешите Bluetooth" } }
    func centralManager(_ c:CBCentralManager,didDiscover p:CBPeripheral,advertisementData:[String:Any],rssi RSSI:NSNumber){ let n=(p.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? "").lowercased(); let uu=(advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []; guard n.contains("glm") || n.contains("bosch") || uu.contains(service) else{return}; c.stopScan(); peripheral=p; p.delegate=self; status="Подключаю \(p.name ?? "Bosch GLM")…"; c.connect(p) }
    func centralManager(_ c:CBCentralManager,didConnect p:CBPeripheral){ status="Ищу канал измерений…"; p.discoverServices([service]) }
    func centralManager(_ c:CBCentralManager,didFailToConnect p:CBPeripheral,error:Error?){ status="Не удалось подключить Bosch" }
    func peripheral(_ p:CBPeripheral,didDiscoverServices error:Error?){ guard error==nil, let s=p.services?.first(where:{$0.uuid==service}) else { status="BLE-сервис не найден"; return }; p.discoverCharacteristics([chUUID],for:s) }
    func peripheral(_ p:CBPeripheral,didDiscoverCharacteristicsFor s:CBService,error:Error?){ guard error==nil, let ch=s.characteristics?.first(where:{$0.uuid==chUUID}) else { status="Канал измерений не найден"; return }; p.setNotifyValue(true,for:ch); if ch.properties.contains(.write){p.writeValue(startCmd,for:ch,type:.withResponse)}else if ch.properties.contains(.writeWithoutResponse){p.writeValue(startCmd,for:ch,type:.withoutResponse)}; status="Bosch подключён — сделайте измерение" }
    func peripheral(_ p:CBPeripheral,didUpdateValueFor ch:CBCharacteristic,error:Error?){ guard error==nil,ch.uuid==chUUID,let d=ch.value else{return}; let b=[UInt8](d); guard b.count>=11,b[0]==0xC0,b[1]==0x55 else{return}; let bits=UInt32(b[7])|(UInt32(b[8])<<8)|(UInt32(b[9])<<16)|(UInt32(b[10])<<24),m=Float(bitPattern:bits); guard m.isFinite,m>0.001,m<100 else{return}; let mm=Int((Double(m)*1000).rounded()); last=mm; onMeasurement?(mm) }
}

struct BoschCaptureScreen: View {
    let returnURL:URL; @StateObject var bosch=BoschManager(); @Environment(\.dismiss) var dismiss; @State var returning=false
    var body:some View {
        VStack(spacing:20){ Spacer(); Image(systemName:"ruler").font(.system(size:70)); Text("Bosch GLM").font(.largeTitle.bold()); Text(bosch.status).multilineTextAlignment(.center).foregroundStyle(.secondary); if let mm=bosch.last { Text("\(mm) мм").font(.system(size:44,weight:.black,design:.rounded)) }; Spacer(); Button("Отмена"){bosch.stop();dismiss()}.buttonStyle(.bordered) }.padding(24).onAppear{ bosch.onMeasurement={mm in guard !returning else{return}; returning=true; DispatchQueue.main.asyncAfter(deadline:.now()+0.35){bosch.stop();CallbackCodec.bosch(mm,to:returnURL)} }; bosch.start() }.onDisappear{bosch.stop()}
    }
}
