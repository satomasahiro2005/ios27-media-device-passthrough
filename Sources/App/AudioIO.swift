//  AudioIO.swift
//  拡張から届いた PCM をローパスに通して、スピーカーへ返す。
//
//  なぜ鳴らすのが本体で、拡張ではないのか（いずれも実機で確定）:
//    - 拡張プロセスは AVAudioSession を開けない（'msrv'）。
//    - 本体に com.apple.developer.media-device-extension を付けると、
//      本体まで全カテゴリで開けなくなる（'!pla'）。
//      MediaExperience の _CMSUtility_FetchSessionEntitlements が
//      配列の要素数を見て hasMediaDeviceEntitlement を立てるため。
//      だから entitlement は拡張側にだけ置き、App.entitlements は空にしてある。
//  つまり「サンプルを受けるのは拡張、音を出すのは本体」の 2 プロセスになる。
//
//  **MPNowPlayingInfoCenter / MPRemoteCommandCenter を使わない。**
//  now playing 能力を名乗ると、MediaExperience がこのセッションを SystemMusic の
//  ルーティングコンテキストへ移し、routeSharingPolicy を LongFormAudio(1) に書き換える。
//  その方針のアプリは全部同じ出力先へ流れる＝いま選ばれている Passthrough なので、
//  自分の音が仮想デバイスへ戻る（実機で確認。名乗らない側は 6 回とも起きなかった）。

import AVFoundation
import Darwin
import os

/// 音のスレッドだけが触る置き場。確保はここで先に済ませる。
private final class RenderState {
    /// 1 回のコールバックで扱えるフレーム数の上限。
    let capacity: Int
    /// 出力のレート。48000 とは限らない（機器側が決める）。
    let sampleRate: Double

    /// リンクから受けるインターリーブ（capacity * 2）。
    let interleaved: UnsafeMutablePointer<Float>
    /// 並べ替えたあとのプレーナ（capacity * 2）。L が前半、R が後半。
    let planar: UnsafeMutablePointer<Float>
    /// フィルタは AudioIO が持っているものを借りる。UI から触るため。
    let lpf: LowPass

    init(capacity: Int, sampleRate: Double, lpf: LowPass) {
        self.capacity = capacity
        self.sampleRate = sampleRate
        self.lpf = lpf
        interleaved = .allocate(capacity: capacity * 2)
        planar = .allocate(capacity: capacity * 2)
        interleaved.initialize(repeating: 0, count: capacity * 2)
        planar.initialize(repeating: 0, count: capacity * 2)
    }

    deinit {
        interleaved.deallocate()
        planar.deallocate()
    }
}

@MainActor
final class AudioIO: ObservableObject {

    static let shared = AudioIO()

    private let log = Logger(subsystem: "ai.nemut.mdepass", category: "audio")

    /// mediaServicesWereReset のあとは古い engine が死んでいて二度と start しない。
    /// 作り直せるように let ではなく var。
    private var engine = AVAudioEngine()
    private var node: AVAudioSourceNode?
    private var render: RenderState?

    /// UI から触るローパス。engine を組み直しても同じものを使い回す。
    let lpf = LowPass()

    private static let capacity = 4096

    @Published var running = false
    @Published var listening = false
    @Published var hasPeer = false
    @Published var received: UInt64 = 0
    @Published var bufferedFrames: UInt32 = 0
    @Published var sampleRate: Double = 48000
    @Published var status = "Waiting for the extension"
    @Published var route = "—"
    /// 出力先が仮想デバイス Passthrough のままか。鎖が自分に戻っている。
    @Published var loopback = false

    /// カットオフ（Hz）。スライダはこれを対数で動かす。
    @Published var cutoff: Double = 20000 {
        didSet { lpf.cutoff = Float(cutoff) }
    }

    /// 中断中は再開しない。中断中の setActive(true) は失敗するだけなので、
    /// tick が叩き続けることになる。
    private var interrupted = false
    /// start() が失敗したとき、次を試すまでの間隔（秒）を稼ぐ。
    private var lastStartAttempt: Double = 0
    private var observers: [NSObjectProtocol] = []

    private init() {
        // 拡張はいつ繋いでくるか分からないので、起動と同時に待ち受ける。
        // 拡張側は「作る・待つ」が全部禁じられている（bind も deny）ので、
        // 待ち受けを持てるのはこちらだけ。
        if !MDPLinkReceiver.shared.start() {
            status = "Cannot open the listening socket"
        }
        lpf.cutoff = Float(cutoff)
        observeSession()
    }

    // MARK: - セッション側の出来事

    private func observeSession() {
        let nc = NotificationCenter.default

        // 経路変更も中断もメインスレッド以外から飛ぶことがあるので queue: .main で受ける。
        observers.append(nc.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshRoute() }
            })

        observers.append(nc.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main) { [weak self] note in
                // 既定値を 0 にしない。rawValue 0 は .began なので、
                // 型の入っていない通知が来たら音を止めることになる。
                guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                else { return }
                let opts = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                Task { @MainActor in self?.handleInterruption(raw: raw, options: opts) }
            })

        observers.append(nc.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.handleMediaServicesReset() }
            })
    }

    /// 着信などで OS がセッションを落としたとき。
    ///
    /// これを見ていないと、engine は止まっているのに running は true のまま
    /// （stop() を通っていないので）、peer も TCP が生きているので true のままになり、
    /// followPeer の条件が両方とも成り立たず音が戻らない。
    private func handleInterruption(raw: UInt, options: UInt) {
        guard let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            interrupted = true
            if running { stop(keepListening: true) }
            status = "Interrupted"
        case .ended:
            interrupted = false
            let resume = AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume)
            // shouldResume が無いときは何もしない。拡張が繋がったままなら tick が拾う。
            if resume { start() }
        @unknown default:
            interrupted = false
        }
    }

    /// メディアサービスが落ちて作り直されたとき。
    /// 古い AVAudioEngine も古いセッションの設定も死んでいるので、全部作り直す。
    private func handleMediaServicesReset() {
        log.notice("media services were reset")
        stop(keepListening: true)
        interrupted = false
        engine = AVAudioEngine()
        node = nil
        lastStartAttempt = 0
        followPeer()
    }

    // MARK: - 開始・停止

    /// 拡張が繋がっている間だけ鳴らす。
    ///
    /// 本体が前面に居るうちに繋がせる前提のサンプルなので、この形にしてある。
    /// 背面へ回ったまま長く使うなら、繋がっていなくても無音を出し続ける方がよい。
    /// UIBackgroundModes の audio は「実際に鳴らしている間」だけアプリを生かすので、
    /// 止めると 127.0.0.1 の待ち受けごと眠り、拡張の connect が errno=61 で弾かれる。
    private func followPeer() {
        // running だけを見ると取りこぼす。中断で OS が engine を止めても
        // stop() を通らないので running は true のまま残る。食い違いを直接見る。
        let alive = running && engine.isRunning

        if hasPeer && !alive {
            guard !interrupted else { return }
            // start() が失敗し続けるとき（中断中の setActive など）に
            // 毎目盛り叩かないよう、1 秒は空ける。
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastStartAttempt >= 1 else { return }
            start()
        } else if !hasPeer && alive {
            stop(keepListening: true)
        }
    }

    func start() {
        // 失敗しても次まで 1 秒空けるため、入口で押しておく（followPeer が見る）。
        lastStartAttempt = ProcessInfo.processInfo.systemUptime
        stop(keepListening: true)

        if !MDPLinkReceiver.shared.listening {
            guard MDPLinkReceiver.shared.start() else {
                status = "Cannot open the listening socket"
                return
            }
        }

        let session = AVAudioSession.sharedInstance()
        do {
            // .playAndRecord は既定で Bluetooth の出力を候補から外す。
            // .allowBluetoothA2DP を足さないとワイヤレスイヤホンへ出せない
            // （.allowBluetooth だけだと HFP のモノラルに落ちる）。
            // .mixWithOthers は必須。外すと、音を出している側のアプリを黙らせてしまう。
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.defaultToSpeaker, .mixWithOthers,
                                              .allowBluetoothA2DP])
            try session.setPreferredSampleRate(48000)
            // 遅延の大半は受け側の再同期の置き場（MDPLinkReceiver.targetFrames、
            // 2048 フレーム＝約 43ms）なので、ここを詰めても効き目は小さい。
            try session.setPreferredIOBufferDuration(0.005)
            try session.setActive(true)

            // routeSharingPolicy はこちらが一度も設定していない。
            // 1（LongFormAudio）が出たら、系が SystemMusic へ移したということ。
            // now playing を名乗っていなければ 0 のままになる。
            log.notice("session rsp=\(session.routeSharingPolicy.rawValue)")
        } catch {
            let ns = error as NSError
            status = "Audio session failed: \(ns.domain) \(ns.code)"
            log.error("session NG \(ns.domain, privacy: .public) \(ns.code)")
            return
        }

        let sr = session.sampleRate > 0 ? session.sampleRate : 48000
        // リンクは 48kHz 固定（LocalLink.h / MDPDriver.m の kSampleRate）。
        // setPreferredSampleRate は要求でしかなく、.mixWithOthers なので
        // 先に鳴らしているアプリがハードウェアのレートを握っていれば通らない。
        // 通らないまま流すと音程と速さがずれ、受信の輪も溜まるか枯れるかする。
        // 止めると打つ手が無くなるので鳴らすが、黙って進めない。
        let rateOK = abs(sr - 48000) < 1

        let state = RenderState(capacity: Self.capacity, sampleRate: sr, lpf: lpf)
        lpf.reset()
        render = state

        // **standardFormat は非インターリーブ（プレーナ）。**
        // これが出力側の約束になる。
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!

        let src = AVAudioSourceNode { _, _, frameCount, ablPtr -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(ablPtr)
            let n = min(Int(frameCount), state.capacity)
            let p = state.planar
            let s = state.interleaved

            // 1. リンクから受ける（float32 インターリーブ・2ch・48kHz）。
            //    足りない分は receiver 側が無音で埋める。
            _ = MDPLinkReceiver.shared.readInterleaved(s, frames: UInt32(n))

            // 2. プレーナへ並べ替える。L を前半、R を後半へ。
            for i in 0..<n {
                p[i] = s[i * 2]
                p[n + i] = s[i * 2 + 1]
            }

            // 3. ローパスを通す。
            state.lpf.process(p, frames: n, sampleRate: Float(state.sampleRate))

            // 4. 出力へ書く。**面ごとに書く。**
            //
            //    standardFormat で繋いでいるので ABL には面が 2 つ来る。
            //    abl[0] が L、abl[1] が R で、どちらも大きさはフレーム数ぶんしか無い。
            //    ここへ L,R,L,R をそのまま書くと、右が無音のまま残り、
            //    しかも 1 面に 2 倍のサンプルを書くので溢れる。
            //    一度これで詰まっているので、面の数を見てから書く。
            if abl.count >= 2,
               let l = abl[0].mData?.assumingMemoryBound(to: Float.self),
               let r = abl[1].mData?.assumingMemoryBound(to: Float.self) {
                for i in 0..<n {
                    l[i] = p[i]
                    r[i] = p[n + i]
                }
                for i in n..<Int(frameCount) {
                    l[i] = 0
                    r[i] = 0
                }
            } else if let o = abl[0].mData?.assumingMemoryBound(to: Float.self),
                      abl[0].mNumberChannels == 2 {
                // 面が 1 つ＝インターリーブで来たとき。上の format を渡している限り
                // 通らないが、通ったときに L だけを半分の速さで鳴らさないため。
                for i in 0..<n {
                    o[i * 2] = p[i]
                    o[i * 2 + 1] = p[n + i]
                }
                for i in n..<Int(frameCount) {
                    o[i * 2] = 0
                    o[i * 2 + 1] = 0
                }
            } else {
                // どちらでもない並び（モノラルなど）。書き方が分からないまま
                // 触ると、前の周回の中身がそのまま鳴る。無音で埋めて黙らせる。
                for i in 0..<abl.count {
                    if let d = abl[i].mData { memset(d, 0, Int(abl[i].mDataByteSize)) }
                }
            }
            return noErr
        }

        engine.attach(src)
        engine.connect(src, to: engine.mainMixerNode, format: fmt)
        node = src

        do {
            try engine.start()
        } catch {
            let ns = error as NSError
            status = "Audio engine failed: \(ns.domain) \(ns.code)"
            return
        }

        running = true
        interrupted = false
        sampleRate = sr
        status = rateOK ? "Running"
                        : String(format: "Running at %.0f Hz, the link is fixed at 48000 Hz", sr)
        refreshRoute()
        log.notice("start sr=\(sr) route=\(self.route, privacy: .public)")
    }

    func stop(keepListening: Bool = false) {
        if let src = node { engine.detach(src) }
        node = nil
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false)
        if !keepListening { MDPLinkReceiver.shared.stop() }
        lpf.reset()
        render = nil
        // start() は毎回ここを通るので、同じ値を書かない（publish が増えるだけ）。
        if running { running = false }
        let idle = hasPeer ? "Stopped" : "Waiting for the extension"
        if status != idle { status = idle }
    }

    // MARK: - 見直し

    /// 状態の見直し。画面から数 Hz で呼ぶ。
    /// 代入はすべて「変わったときだけ」。@Published は同じ値でも publish する。
    func tick() {
        let link = MDPLinkReceiver.shared

        let nowListening = link.listening
        if listening != nowListening { listening = nowListening }

        let nowPeer = link.hasPeer
        if hasPeer != nowPeer {
            // 既定の privacy だと文字列が <private> で潰れてログから読めない。
            log.notice("peer \(nowPeer ? "up" : "down", privacy: .public) recv=\(link.receivedFrames)")
            hasPeer = nowPeer
        }

        let nowReceived = link.receivedFrames
        if received != nowReceived { received = nowReceived }

        let nowBuffered = link.bufferedFrames
        if bufferedFrames != nowBuffered { bufferedFrames = nowBuffered }

        followPeer()
        refreshRoute()
    }

    private func refreshRoute() {
        let outs = AVAudioSession.sharedInstance().currentRoute.outputs
        let names = outs.map(\.portName).joined(separator: ", ")
        let now = names.isEmpty ? "—" : names
        if route != now { route = now }

        // 出力先が仮想デバイスなら、出した音がそのまま拡張へ戻る
        // （出力 → ドライバ → TCP → 自分の入力 → 出力）。float32 のまま回るので
        // 丸めもクリップも起きず、レベルだけが上がってスピーカーには何も届かない。
        //
        // 名前で見る。ドライバは kAudioDeviceTransportTypeRemoteStreaming で名乗るので
        // portType は .airPlay になり、本物の AirPlay スピーカーと区別がつかない。
        // 名前は MDPDriver.m が返す "Passthrough" 固定。
        let nowLoop = outs.contains {
            $0.portName.localizedCaseInsensitiveContains("Passthrough")
        }
        if loopback != nowLoop { loopback = nowLoop }
    }
}
