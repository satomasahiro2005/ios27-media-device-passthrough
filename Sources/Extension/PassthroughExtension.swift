//  MDE Passthrough — Media Device Extension (iOS 27+)
//
//  ルートピッカーに Passthrough を1台出し、選ばれたらシステム音声のサンプルを受け取る。
//  API は Xcode 27 の MediaDevice.swiftinterface から起こしたもので、推測は含まない。
//
//  CoreAudio/AudioServerPlugIn.h に書かれている制約:
//    - AudioServerPlugIn は「単一の出力デバイス」しか提示できない
//    - transport type は kAudioDeviceTransportTypeRemoteScreen か RemoteStreaming
//      違うと登録が kAudioHardwareIllegalOperationError で失敗する
//    - デバイスの UID は MediaOutputDevice.id と一致していること
//
//  MediaOutputDevice.init? は failable で、requiredNetworkEndpoints が必須引数。
//  ネットワーク上の受信機を前提にした設計なので、ローカル完結のデバイスでも
//  実在して到達できる口を渡す必要がある。ここでは本体が bind している
//  127.0.0.1:47101 をそのまま名乗る（下の localDevice を見ること）。

import Foundation
import MediaDevice
import Network
import UniformTypeIdentifiers
import os

// 3 箇所で同じ文字列を使う:
//   1. entitlement com.apple.developer.media-device-extension の値
//   2. Info.plist の UTExportedTypeDeclarations / UTTypeIdentifier
//   3. protocolType
let kProtocolID = "media-device-protocol.ai.nemut.mdepass"

let log = Logger(subsystem: "ai.nemut.mdepass", category: "extension")

@main
@available(iOS 27.0, *)
final class PassthroughExtension: MediaDeviceExtension, RealtimeSampleHandling {

    // MARK: - MediaDeviceExtension

    var protocolType: UTType { UTType(exportedAs: kProtocolID) }

    var supportsSimultaneousSessions: Bool { false }

    lazy var routingManager: MediaDeviceRoutingManager = .routingManager(for: self)

    private var reportTimer: Timer?

    /// 終える。呼び出しの最中に落とさないよう次の回に回す。
    ///
    /// AudioServerPlugInRegisterMediaDeviceExtension に対になる解除が無いので、
    /// 登録を落とす代わりにプロセスごと終える。次に選ばれたときは
    /// システムが新しいプロセスを立ち上げ、毎回 1 回目の登録になる。
    ///
    /// **すぐには落とさない。** 系は activation のとき、この拡張のプロセスへ
    /// `MediaDeviceDiscoveryOrBridge` の assertion を取りに来る。次の回で
    /// `exit(0)` を撃つと、その前に居なくなっていることがある。実機のログ:
    /// ```
    /// Error acquiring assertion: <Error Domain=RBSAssertionErrorDomain Code=2
    ///   "Specified target process NNNNN does not exist">
    /// Failed to get MediaDeviceDiscoveryOrBridge assertion
    /// -FigCustomEndpoint- signalled err=-16729
    /// Evicted device from cache for protocol '…' due to activation failure
    /// All devices evicted for protocol '…'; removing protocol entry
    /// ```
    /// 取れないと activation failure 扱いになり、**この protocol のキャッシュごと
    /// 捨てられて**ルートピッカーの項目が回ったまま残る。
    /// 猶予を置いて、系の後始末が終わってから落ちる。
    private static let quitGrace: TimeInterval = 2

    private func quit(_ why: String) {
        log.notice("終了する: \(why, privacy: .public) grace=\(Self.quitGrace)")
        reportTimer?.invalidate(); reportTimer = nil
        MDPDriver.shared.stopCapture()
        MDPLinkSender.shared.stop()
        MDPDriver.shared.unpublish()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.quitGrace) {
            log.notice("終了する: 猶予が明けた")
            exit(0)
        }
    }

    /// デバイスの id。AudioServerPlugIn の kAudioDevicePropertyDeviceUID と一致させる。
    ///
    /// **固定値でなければならない。** 一度プロセスごとに作り直してみたが、
    /// 探索と有効化が別プロセスで走ることがあるため、一覧に出したデバイスと
    /// ドライバが名乗るデバイスが食い違い、ルートピッカーに 2 つ出て
    /// どちらも繋がらなくなった。
    ///
    /// 引き換えに、古い登録が audiomxd に残ったままだと同じ UID の死んだ port
    /// （conn:1 quies:1 rout:0）に衝突する。そうなると端末の再起動でしか消えない。
    /// AudioServerPlugInRegisterMediaDeviceExtension に対になる解除が無いのが元。
    static let deviceUUID = UUID(uuidString: "4D444550-4153-4853-A000-000000000001")!

    /// 本体（MDE Passthrough）の MDPLinkReceiver が bind している口。
    /// Sources/Shared/LocalLink.h:23-24 の MDP_LINK_PORT / MDP_LINK_HOST と同じもの。
    /// 数字を写さずマクロを引くのは、片方だけ変えられるのを防ぐため。
    /// MDP_LINK_PORT は bridging header 経由（Extension-Bridging-Header.h:2）。
    /// もし `cannot find 'MDP_LINK_PORT' in scope` で止まったら、
    /// bridging header が target に入っているかを見ること。
    static let linkEndpoint: NWEndpoint = .hostPort(
        host: .ipv4(.loopback),
        port: NWEndpoint.Port(rawValue: UInt16(MDP_LINK_PORT)) ?? 47101
    )

    /// **requiredNetworkEndpoints には実在して到達できる口を渡す。**
    ///
    /// ここを 0 番（`NWEndpoint.Port.any`）にしていると、ルートピッカーで選んだ
    /// 1.5 秒後にスピーカーへ戻される。失敗理由は
    /// `AVOutputContextDeviceConnectionFailureReasonMDERouteRevertedToLocal`。
    ///
    /// 拡張の中で `NWListener` を立てて実ポートを渡す、という設計は通らない。
    /// **拡張は待ち受けを禁じられている**（`deny(1) network-bind local:*:0`）ので
    /// listener が必ず失敗し、port が nil のまま 0 番に落ちる。
    /// 待ち受けはアプリ側が持ち、拡張は繋ぎに行く。だからここは
    /// アプリが bind している 127.0.0.1:47101 をそのまま名乗る。
    ///
    /// 音はこの口を通らない（サンプルは AudioServerPlugIn 経由で来る）。
    /// システムが方針の許可に使うので、実在して到達できることだけが要る。
    ///
    /// 他の引数は切る判断には入らない。`canGroupWithCurrentlyActivatedDevices` も
    /// `deviceType` も `volumeControl` も読まれていない。
    private lazy var localDevice: MediaOutputDevice? = {
        let eps: [NWEndpoint] = [Self.linkEndpoint]
        // privacy: .public にしないと <private> で潰れる。直ったかどうかはこの行で見る。
        log.notice("endpoints=\(eps.map { $0.debugDescription }.joined(separator: ","), privacy: .public)")
        return MediaOutputDevice(
            id: Self.deviceUUID,
            displayName: "Passthrough",
            capabilities: [.realtimeAudioStreaming],
            canGroupWithCurrentlyActivatedDevices: false,
            deviceType: .hifiSpeaker,
            // **音量はこちらで持たない。**
            // .relative だと Now Playing（ロック画面やコントロールセンター）に
            // + と − のボタンが出る。押されると setVolume が来て、
            // こちらが掛けた減衰と、鎖に入れた Volume と、端末の音量とで
            // 三重に掛かる。選択肢は none / absolute / relative の 3 つで、
            // none にするとボタンごと出なくなる（MediaDevice.swiftinterface:125-128）。
            // 音量は鎖の Volume か端末の音量ボタンで変える。
            // canMute も同じ理由で外す。鎖の頭の電源を切れば素通しになる。
            volumeControl: .none,
            canMute: false,
            requiredNetworkEndpoints: eps,
            txtRecords: [],
            supportsSimultaneousSessions: false
        )
    }()

    required init() {
        log.notice("PassthroughExtension init")
    }

    func startDeviceDiscovery() {
        guard let dev = localDevice else {
            log.error("MediaOutputDevice の init が nil を返した。endpoints の渡し方を変える")
            routingManager.discoveryFailed(MediaDeviceError(.discoveryFailed))
            return
        }
        // ここも privacy: .public。既定だと <private> で潰れて、
        // 何を名乗ったのかログから読めない。
        log.notice("startDeviceDiscovery -> foundDevice \(dev.description, privacy: .public)")
        routingManager.foundDevice(dev)
    }

    func stopDeviceDiscovery() {
        if let dev = localDevice { routingManager.lostDevice(dev) }
        log.notice("stopDeviceDiscovery")
    }

    func activateDevice(_ device: MediaOutputDevice,
                        session: MediaOutputSession,
                        for deviceFeatures: MediaOutputDevice.Capabilities) {
        log.notice("activateDevice features=\(deviceFeatures.description)")
        // ヘッダの注意: activate 直後に速やかにオーディオデバイスが現れないと
        // システムが deactivate して "Unable to Connect" になる。
        // だから startRealtimeSampleDelivery を待たずにここで publish する。
        let st = MDPDriver.shared.publish(withDeviceUID: Self.deviceUUID.uuidString)
        if st != noErr {
            log.error("AudioServerPlugIn の登録に失敗 OSStatus=\(st)")
            routingManager.failedToActivateDevice(device, session: session,
                                                  error: MediaDeviceError(.connectionFailed))
            // 失敗したまま生き残ると、次の activate も同じ死んだ登録に当たる。
            quit("publish に失敗した")
            return
        }
        routingManager.activatedDevice(device, session: session)
    }

    func connectUsingPairingCode(_ pairingCode: String?,
                                 to device: MediaOutputDevice,
                                 session: MediaOutputSession) {
        routingManager.activatedDevice(device, session: session)
    }

    /// **2 回目以降が繋がらない原因はここではない。** 先に MDPDriver.m の
    /// publishWithDeviceUID: にある長いコメントを読むこと。要点だけ書くと、
    /// 失敗は audiomxd の
    ///   customEndpoint_Activate: VA port type 'rstm' already connected;
    ///     skipping port-publication wait
    /// で決まっていて、この行が出るのは activateDevice が届く 4ms 前
    /// （実機のログ 02:40:01.489240 / 02:40:01.493678）。
    /// つまり Swift 側で何を呼ぼうと結果は動かない。効くのは
    /// 「前回の publish が残した rstm ポートを次の activate までに消す」ことだけで、
    /// それは unpublish の中でやっている。
    ///
    /// 下の foundDevice はドキュメントの言う口ではない（updateDevices が正しい）。
    /// stopDeviceDiscovery の lostDevice も同じく doc に無い。どちらも直す価値はあるが、
    /// gate の分岐とは別の話なので、unpublish の結果を 1 往復見てから触ること。
    /// 同時に変えると、どちらが効いたのか分からなくなる。
    func deactivateDevice(_ device: MediaOutputDevice, session: MediaOutputSession) {
        log.notice("deactivateDevice")
        reportTimer?.invalidate()
        reportTimer = nil
        MDPDriver.shared.stopCapture()
        MDPLinkSender.shared.stop()
        MDPDriver.shared.unpublish()

        // **このプロセスを終える。**
        //
        // AudioServerPlugInRegisterMediaDeviceExtension に対になる解除が無い。
        // 一度登録すると、このプロセスが生きているかぎり audiomxd に残る。
        // デバイスの UID は MediaOutputDevice.id と一致させる必要があるので固定で、
        // 次に選ばれたときは同じ UID の死んだポート（conn:1 quies:1 rout:0）に当たる。
        // そのとき audiomxd は
        //   customEndpoint_Activate: VA port type 'rstm' already connected;
        //     skipping port-publication wait
        // と判断して素通しし、誰も IO を出さないまま "Unable to Connect" になる。
        // この行が出るのは activateDevice が届く 4ms 前なので、
        // **Swift 側で何を呼んでも結果は動かない。**
        //
        // 端末を再起動すると直るのは、プロセスが入れ替わって 1 回目の登録に戻るから。
        // ならば毎回 1 回目にすればよい。次に選ばれたとき、システムが
        // 新しいプロセスを立ち上げ直す。
        //
        // 以前は unpublish の中の NULL 登録が落ちることで結果的に同じことが
        // 起きていた。落ち方が決まらないので、意図して終える形にした。
        //
        // 終えるのは routingManager への返事が済んだあと。
        // いま呼び出しの最中なので、次の回に回す。
        quit("deactivate された")
    }

    // MARK: - 音量（持たない）
    //
    // volumeControl: .none / canMute: false にしてあるので、これらは呼ばれない。
    // それでも protocol の要件なので残す。**中身は空にしてある。**
    // 万一システムが呼んでも、ドライバの減衰を動かさない。
    // 動かすと、鎖の Volume と端末の音量と合わせて三重に掛かる。

    func setVolume(_ volume: Float, for device: MediaOutputDevice) {
        log.notice("setVolume が来た（volumeControl は .none のはず）v=\(volume)")
    }

    func volume(for device: MediaOutputDevice) -> Float { 1.0 }

    func changeVolume(by increments: Int, for device: MediaOutputDevice) {
        log.notice("changeVolume が来た（volumeControl は .none のはず）d=\(increments)")
    }

    func muteDevice(_ device: MediaOutputDevice) {
        log.notice("muteDevice が来た（canMute は false のはず）")
    }

    func isDeviceMuted(_ device: MediaOutputDevice) -> Bool { false }

    // MARK: - URL 再生（使わない）

    func startSession(_ session: MediaOutputSession, identifier: String?, url: URL) {
        log.notice("startSession url=\(url.absoluteString) — realtime のみ対応")
        routingManager.sessionFailed(session, error: MediaDeviceError(.sessionFailed))
    }

    func stopSession(_ session: MediaOutputSession) {
        log.notice("stopSession")
    }

    func sendData(_ data: Data, toApplication applicationIdentifier: String,
                  session: MediaOutputSession) {
    }

    // MARK: - RealtimeSampleHandling

    func startRealtimeSampleDelivery(session: MediaOutputSession) {
        log.notice("startRealtimeSampleDelivery session=\(session.id)")

        // 受け取ったサンプルは TCP で本体（MDE Passthrough）へ送る。鳴らすのは本体側。
        // 拡張は「作る・待つ」が全部禁じられている（ファイル/共有メモリ/bind すべて deny）ので、
        // App Group の共有リングもドライバ内のループ（出力→入力）も使えない。
        // 外へ繋ぐのは許されているので、そちら 1 本にした。
        MDPLinkSender.shared.start()
        MDPDriver.shared.startCapture { planes, channels, frames, _ in
            MDPLinkSender.shared.pushInterleaved(planes[0], frames: frames, channels: channels)
        }

        reportTimer?.invalidate()
        reportTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            _ = self
            log.notice("受信 frames=\(MDPDriver.shared.framesDelivered) 接続=\(MDPLinkSender.shared.connected) 送信=\(MDPLinkSender.shared.sentFrames)")
        }
    }

    func stopRealtimeSampleDelivery(session: MediaOutputSession) {
        log.notice("stopRealtimeSampleDelivery")
        reportTimer?.invalidate()
        reportTimer = nil
        MDPDriver.shared.stopCapture()
    }
}
