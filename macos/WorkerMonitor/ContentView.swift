import SwiftUI

struct ContentView: View {
    @State private var model = WorkerMonitorModel()

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 16) {
                statusSection
                controlsSection
                Spacer(minLength: 0)
            }
            .padding(20)
            .navigationSplitViewColumnWidth(min: 260, ideal: 300)
        } detail: {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Worker Log")
                        .font(.title2.weight(.semibold))
                    Spacer()
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        model.refresh()
                    }
                }

                Text(model.currentJob)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                ScrollView {
                    Text(model.logTail.isEmpty ? "No worker log found." : model.logTail)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            }
            .padding(20)
        }
        .task {
            model.refresh()
            model.startPolling()
        }
        .onDisappear {
            model.stopPolling()
        }
        .alert("Worker Command Failed", isPresented: $model.showsError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage)
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(model.isRunning ? "Running" : "Stopped", systemImage: model.isRunning ? "checkmark.circle.fill" : "xmark.circle")
                .font(.title2.weight(.semibold))
                .foregroundStyle(model.isRunning ? .green : .red)

            LabeledContent("Session", value: model.sessionName)
            LabeledContent("Wrapper PID", value: model.workerPID)
            LabeledContent("Whisper PID", value: model.whisperPID)
            LabeledContent("Updated", value: model.lastUpdatedText)
        }
    }

    private var controlsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Repository")
                .font(.headline)

            TextField("Repository path", text: $model.repositoryPath)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    model.refresh()
                }

            HStack {
                Button("Start", systemImage: "play.fill") {
                    model.startWorker()
                }
                .disabled(model.isRunning)

                Button("Stop", systemImage: "stop.fill") {
                    model.stopWorker()
                }
                .disabled(!model.isRunning)
                .tint(.red)
            }

            Button("Open Log Folder", systemImage: "folder") {
                model.openLogFolder()
            }
        }
        .buttonStyle(.bordered)
    }
}
