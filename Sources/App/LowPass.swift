//  LowPass.swift
//  一次（6dB/oct）のローパスを 1 本だけ。
//
//  このサンプルに DSP は要らないが、何も掛けないと「本当にこのアプリを
//  通っているのか」が耳で分からない。カットオフを下げて高域が落ちれば、
//  拡張 → TCP → このアプリ → スピーカー の経路が通っている証拠になる。
//
//  音のスレッドから呼ぶので、確保も待ちもロックもしない。

import Darwin

final class LowPass {

    /// 目標のカットオフ（Hz）。UI（メインスレッド）が書き、音のスレッドが読む。
    ///
    /// ロックは取らない。arm64 では 4 バイト境界に揃った float の読み書きは
    /// ちぎれないので、共有するのはこの 1 語だけにしてある。
    /// 仮に古い値を 1 回読んでも、下の寄せ方（1 ブロックにつき 1 歩）で
    /// 次のブロックが追いつく。
    private let target: UnsafeMutablePointer<Float>

    /// 実際に掛かっているカットオフ。ブロックごとに target へ寄せる。
    private var current: Float

    /// 1 次の状態。planar の L / R ぶんで 2 つ。
    private var zL: Float = 0
    private var zR: Float = 0

    init(cutoff: Float = 20000) {
        target = .allocate(capacity: 1)
        target.initialize(to: cutoff)
        current = cutoff
    }

    deinit { target.deallocate() }

    /// UI から触る口。非有限値が来たら開ききった値に倒す。
    /// NaN を 1 つ入れると current が二度と戻らず、以後ずっと無音になる。
    var cutoff: Float {
        get { target.pointee }
        set { target.pointee = newValue.isFinite ? newValue : 20000 }
    }

    /// 経路を組み直すときに呼ぶ。前の音の尻尾を次の start へ持ち越さない。
    func reset() {
        zL = 0
        zR = 0
        current = target.pointee
    }

    /// プレーナのバッファをその場で書き換える。
    /// - Parameters:
    ///   - planar: L が [0..<frames]、R が [frames..<frames*2]。
    ///   - frames: チャンネルあたりのフレーム数。
    ///   - sampleRate: 出力のレート。48000 とは限らない（機器側が決める）。
    func process(_ planar: UnsafeMutablePointer<Float>, frames: Int, sampleRate: Float) {
        guard frames > 0, sampleRate > 0 else { return }

        // ナイキストの手前で止める。超えても 1 - exp(...) が 1 に張り付いて
        // 素通しになるだけだが、表示している値と実際が食い違う。
        let want = min(max(target.pointee, 20), sampleRate * 0.45)

        // ブロックごとに 1 歩だけ寄せる。スライダを動かしている間に係数が飛ぶと、
        // 段差がそのままプツプツと鳴る。
        current += (want - current) * 0.25
        if !current.isFinite { current = want }

        // 一次 IIR: y += a * (x - y)。a は連続時間の 1 - exp(-2π fc / fs)。
        // 双一次変換をしていないので、カットオフがナイキストに近いところでは
        // 実際の -3dB 点が少し下にずれる。PoC なのでこれで足りる。
        var a = 1 - expf(-2 * Float.pi * current / sampleRate)
        if !(a > 0) { a = 0 }
        if a > 1 { a = 1 }

        var y = zL
        for i in 0..<frames {
            y += a * (planar[i] - y)
            planar[i] = y
        }
        // 受け側で非有限値は落としてあるが、ここでも一度だけ見る。
        // IIR は状態が壊れると入力に関係なく壊れたままになる。
        zL = y.isFinite ? y : 0

        y = zR
        for i in 0..<frames {
            let j = frames + i
            y += a * (planar[j] - y)
            planar[j] = y
        }
        zR = y.isFinite ? y : 0
    }
}
