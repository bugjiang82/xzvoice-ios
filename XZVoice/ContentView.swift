import SwiftUI
import AVFoundation

struct ContentView: View {
    @StateObject private var ble = BLEManager()
    @State private var player: AVAudioPlayer?

    var body: some View {
        NavigationView {
            VStack(spacing: 12) {
                connectionCard
                statsCard
                controlBar
                segmentList
                logCard
            }
            .padding(.horizontal)
            .navigationTitle("XZ-Voice")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink("设置") { SettingsView() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private var connectionCard: some View {
        HStack {
            Circle()
                .fill(ble.connected ? Color.green : Color.orange)
                .frame(width: 10, height: 10)
            Text(ble.connected ? "已连接 \(ble.deviceName)" : "未连接")
                .font(.headline)
            Spacer()
            if ble.connected {
                Button("断开") { ble.disconnect() }
                    .font(.footnote)
            } else {
                Button(ble.scanning ? "扫描中..." : "扫描连接") {
                    ble.scanning ? ble.stopScan() : ble.startScan()
                }
                .font(.footnote)
                .disabled(!ble.bluetoothOn)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    private var statsCard: some View {
        HStack {
            stat("MTU", "\(ble.mtu)")
            stat("吞吐", String(format: "%.1f KB/s", ble.throughput / 1024))
            stat("累计", String(format: "%.2f MB", Double(ble.totalAudioBytes) / 1048576))
            stat("段数", "\(ble.segments.count)")
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.subheadline).bold()
            Text(label).font(.caption2).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var controlBar: some View {
        HStack(spacing: 12) {
            Button {
                ble.startRecording()
            } label: {
                Text("▶ 开始录音")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(!ble.connected)

            Button {
                ble.stopRecording()
            } label: {
                Text("■ 停止")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.bordered)
            .disabled(!ble.connected)
        }
    }

    private var segmentList: some View {
        List {
            ForEach(ble.segments.reversed()) { seg in
                HStack {
                    Image(systemName: seg.done ? "waveform" : "hourglass")
                        .foregroundColor(seg.done ? .blue : .secondary)
                    VStack(alignment: .leading) {
                        Text("段 #\(seg.no)")
                            .font(.subheadline).bold()
                        Text(seg.done
                             ? String(format: "%.1f 秒 · %.2f MB", Double(seg.pcmBytes) / 2 / 16000, Double(seg.pcmBytes) / 1048576)
                             : "接收中 \(seg.received)/\(seg.totalADPCM) B")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    if seg.done {
                        Button {
                            play(seg)
                        } label: {
                            Image(systemName: "play.circle.fill")
                                .font(.title2)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    private func play(_ seg: BLEManager.Segment) {
        guard let url = seg.fileURL else { return }
        player = try? AVAudioPlayer(contentsOf: url)
        player?.play()
    }

    private var logCard: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(ble.log.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 10, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(8)
            }
            .background(Color(.systemGray6))
            .cornerRadius(12)
            .frame(height: 150)
            .onChange(of: ble.log.count) { _ in
                proxy.scrollTo("bottom")
            }
        }
    }
}

struct SettingsView: View {
    @AppStorage("xflyyunAppId") private var xfAppId = ""
    @AppStorage("xflyyunApiKey") private var xfApiKey = ""
    @AppStorage("deepseekApiKey") private var dsKey = ""
    @AppStorage("baiduApiKey") private var bdKey = ""
    @AppStorage("baiduSecretKey") private var bdSecret = ""

    var body: some View {
        Form {
            Section("讯飞开放平台（声纹/ASR/TTS）") {
                TextField("App ID", text: $xfAppId)
                SecureField("API Key", text: $xfApiKey)
            }
            Section("DeepSeek（对话/总结）") {
                SecureField("API Key", text: $dsKey)
            }
            Section("百度语音（TTS 回传板子）") {
                TextField("API Key", text: $bdKey)
                SecureField("Secret Key", text: $bdSecret)
            }
            Section {
                Text("Key 只保存在本机，不上传仓库。")
                    .font(.footnote).foregroundColor(.secondary)
            }
        }
        .navigationTitle("设置")
    }
}
