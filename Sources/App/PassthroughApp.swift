//  PassthroughApp.swift
//  MDE Passthrough — iOS 27 の Media Device Extension が運んできた音を鳴らす側。
//
//  画面は 1 枚だけ。開始／停止のボタンは置かない。拡張が繋いできたら鳴り始め、
//  切れたら畳む（AudioIO.followPeer）。ユーザーが操作するのは、
//  ルートピッカーで Passthrough を選ぶことと、下のカットオフだけ。
//
//  **MediaPlayer は import しない。** now playing 能力を名乗ると
//  系がセッションを SystemMusic へ移し、自分の音が仮想デバイスへ戻る。
//  理由は AudioIO.swift の先頭に書いてある。

import Combine
import Foundation
import SwiftUI

@main
struct PassthroughApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

struct ContentView: View {

    @StateObject private var io = AudioIO.shared

    /// 状態表示の更新だけに使う。音の経路とは関係ない。
    private let ticker = Timer.publish(every: 0.3, on: .main, in: .common).autoconnect()

    /// スライダは 0...1 の位置で持ち、200Hz〜20kHz へ対数で写す。
    /// 200 * 100 = 20000 なので、底は 100 でちょうど端まで届く。
    private var knob: Binding<Double> {
        Binding(
            get: { log(io.cutoff / 200) / log(100) },
            set: { io.cutoff = 200 * pow(100, min(max($0, 0), 1)) }
        )
    }

    private var cutoffText: String {
        io.cutoff < 1000
            ? String(format: "%.0f Hz", io.cutoff)
            : String(format: "%.2f kHz", io.cutoff / 1000)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Link") {
                    LabeledContent("Listening",
                                   value: io.listening ? "127.0.0.1:\(MDP_LINK_PORT)" : "no")
                    LabeledContent("Extension",
                                   value: io.hasPeer ? "connected" : "waiting")
                    LabeledContent("Frames received", value: "\(io.received)")
                    LabeledContent("Buffered", value: "\(io.bufferedFrames) frames")
                }

                Section("Output") {
                    LabeledContent("Engine", value: io.running ? "running" : "stopped")
                    LabeledContent("Route", value: io.route)
                    LabeledContent("Sample rate", value: String(format: "%.0f Hz", io.sampleRate))
                    Text(io.status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if io.loopback {
                        Text("This app is playing into the virtual device. "
                             + "The sound is looping back instead of reaching the speaker.")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }

                Section {
                    LabeledContent("Cutoff", value: cutoffText)
                    Slider(value: knob, in: 0...1) {
                        Text("Cutoff")
                    } minimumValueLabel: {
                        Text("200 Hz").font(.caption2)
                    } maximumValueLabel: {
                        Text("20 kHz").font(.caption2)
                    }
                } header: {
                    Text("Low-pass")
                } footer: {
                    Text("One-pole, 6 dB/oct. Drag it down and the highs should go away — "
                         + "that is how you know the audio really passes through this app.")
                }

                Section("How to use") {
                    Text("Play something in another app, open the AirPlay route picker "
                         + "and choose Passthrough. The extension registers an audio device, "
                         + "sends the system audio to this app over 127.0.0.1, and this app "
                         + "plays it back through the speaker.")
                        .font(.footnote)
                }
            }
            .navigationTitle("Passthrough")
        }
        .onReceive(ticker) { _ in io.tick() }
    }
}
