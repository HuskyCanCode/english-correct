import SwiftUI
import AppKit
import EnglishCorrectCore

struct ModelLibraryView: View {
    @ObservedObject var library: ModelLibrary
    @ObservedObject var appModel: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 23) {
            VStack(alignment: .leading, spacing: 10) {
                Text("A model that fits your Mac.").font(.system(size: 34, weight: .medium, design: .serif))
                Text("Choose a lighter model for quick edits, or a larger one for more demanding writing. Both are free to download and run locally.").font(.system(size: 14)).foregroundStyle(.secondary).lineSpacing(4)
            }
            HStack(spacing: 14) {
                Label("\(library.memoryGB) GB on this Mac", systemImage: "desktopcomputer").font(.system(size: 12, weight: .medium))
                Spacer()
                Text("Download with " + appModel.provider.displayName).font(.system(size: 12))
            }.padding(15).contentSurface(cornerRadius: 16, tinted: true)
            HStack(alignment: .top, spacing: 15) {
                ForEach(ModelCatalog.recommendations) { item in modelCard(item) }
            }
            HStack(alignment: .top, spacing: 12) {
                if library.checking { ProgressView().controlSize(.small) }
                Text(library.status).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                Button("Refresh", systemImage: "arrow.clockwise") { library.refresh() }
                    .glassAction().disabled(library.checking || library.isBusy)
            }
            VStack(alignment: .leading, spacing: 12) {
                Label("Download once. Write locally.", systemImage: "lock.shield").font(.system(size: 14, weight: .semibold)).foregroundStyle(GlassTheme.accent)
                Text("Downloads need internet access and are handled by \(appModel.provider.displayName). Model files come from the linked publisher or Ollama registry; your writing is not included in the download request.").font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
                Text("Sizes are approximate and vary by provider. Memory figures are our recommendations. Speed and correction quality depend on your Mac and the text; Fast and Pro are local presets, with no subscription.").font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
                HStack {
                    Button("Open \(appModel.provider.displayName)") { openProvider() }.glassAction()
                    Spacer()
                }
                if appModel.provider == .lmStudio {
                    Text("Requires LM Studio 0.4 or newer with its local server running. Use LM Studio to pause or cancel a download; Stop checking only stops the progress display here.").font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3)
                } else {
                    Text("Start Ollama before downloading. A stopped transfer can reuse partial files when you retry.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }.padding(19).contentSurface(cornerRadius: 18, tinted: false)
        }
        .task(id: appModel.provider.rawValue + appModel.baseURL) { library.configure(appModel.configuration); library.refresh() }
        .alert("Delete downloaded model?", isPresented: Binding(
            get: { library.pendingDeletion != nil },
            set: { if !$0 { library.cancelDeletion() } }
        ), presenting: library.pendingDeletion) { request in
            Button("Cancel", role: .cancel) { library.cancelDeletion() }
            Button("Delete \(request.item.tier)", role: .destructive) {
                appModel.prepareForModelDeletion(request)
                library.confirmDeletion { appModel.modelWasDeleted($0) }
            }
        } message: { request in
            Text(deletionMessage(request))
        }
    }

    private func modelCard(_ item: RecommendedModel) -> some View {
        let installed = library.installedID(item)
        let isActive = library.isSelected(item, modelID: appModel.model)
        let downloading = library.activeDownloadID == item.id
        let preparing = library.preparingID == item.id
        let deleting = library.deletingID == item.id
        return VStack(alignment: .leading, spacing: 15) {
            HStack {
                Image(systemName: item.id == "fast" ? "bolt.fill" : "sparkles").font(.system(size: 23)).foregroundStyle(GlassTheme.accent)
                Spacer()
                Text(isActive ? "ACTIVE" : (installed == nil ? "OPEN WEIGHTS" : "DOWNLOADED"))
                    .font(.system(size: 9, weight: .bold)).tracking(0.8).foregroundStyle(GlassTheme.accent)
                    .padding(.horizontal, 8).padding(.vertical, 5).background(GlassTheme.accent.opacity(0.10), in: Capsule())
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(item.tier).font(.system(size: 30, weight: .medium, design: .serif))
                Text(item.name).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            }
            Text(item.summary).font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(4).frame(minHeight: 62, alignment: .top)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Label("About \(formatSize(item.downloadBytes(for: appModel.provider))) to download", systemImage: "arrow.down.circle")
                Label("\(item.recommendedMemoryGB) GB+ memory recommended", systemImage: "memorychip")
                Label("Apache 2.0 · Q4_K_M", systemImage: "checkmark.seal")
            }.font(.system(size: 11))
            if library.memoryGB < item.recommendedMemoryGB {
                Text("Fast may be a better fit for this Mac’s memory.").font(.system(size: 11)).foregroundStyle(.orange)
            }
            HStack(spacing: 13) {
                Link("Model source ↗", destination: item.sourceURL)
                Link("License ↗", destination: item.licenseURL)
            }.font(.system(size: 11))
            if let update = library.progress[item.id], downloading {
                VStack(alignment: .leading, spacing: 7) {
                    if let fraction = update.fraction { ProgressView(value: fraction) } else { ProgressView().controlSize(.small) }
                    if let complete = update.completedBytes, let total = update.totalBytes {
                        Text("\(formatSize(complete)) of \(formatSize(total))").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
            }
            if let message = library.cardMessages[item.id] {
                Text(message).font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3).textSelection(.enabled)
            }
            Spacer(minLength: 0)
            if deleting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Deleting…").font(.system(size: 12))
                }.frame(maxWidth: .infinity)
            } else if downloading {
                Button(appModel.provider == .lmStudio ? "Stop checking" : "Stop download") { library.stopChecking() }
                    .glassAction().frame(maxWidth: .infinity).controlSize(.large)
            } else if installed != nil {
                Button(preparing ? "Preparing…" : (isActive ? "Using \(item.tier)" : "Use \(item.tier)")) {
                    library.use(item) { id in appModel.model = id; appModel.connectionStatus = "\(item.tier) is ready · \(appModel.provider.displayName)" }
                }.glassAction(prominent: true).controlSize(.large).frame(maxWidth: .infinity).disabled(library.isBusy || isActive)
                Button("Delete \(item.tier)…", role: .destructive) { library.requestDeletion(item) }
                    .glassAction().font(.system(size: 11)).frame(maxWidth: .infinity).disabled(library.isBusy || library.checking)
            } else {
                Button("Download \(item.tier)") { library.download(item) }
                    .glassAction(prominent: true).controlSize(.large).frame(maxWidth: .infinity).disabled(library.isBusy)
                if library.savedJob(item) != nil {
                    Button("Resume checking") { library.resume(item) }.glassAction().font(.system(size: 11)).disabled(library.isBusy)
                }
            }
        }.padding(20).frame(maxWidth: .infinity, minHeight: 390, alignment: .topLeading)
            .contentSurface(cornerRadius: 20, tinted: false)
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(isActive ? GlassTheme.accent.opacity(0.7) : Color.primary.opacity(0.06), lineWidth: isActive ? 1.5 : 1))
    }

    private func formatSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
    private func deletionMessage(_ request: ModelDeletionRequest) -> String {
        let storage = request.provider == .lmStudio
            ? "Its downloaded files will move to Trash. Empty Trash later to free the disk space."
            : "Its downloaded copy will be removed from Ollama. Files shared with other models may remain."
        let active = request.matchesSelectedModel(appModel.model)
            ? " This is your active writing model; choose or download a model before checking more text."
            : ""
        return "\(request.item.name) (Q4_K_M)\n\(request.installedModelID)\n\n\(storage) Other apps using this model will also be affected.\(active)\n\nYou can download \(request.item.tier) again from this card."
    }
    private func openProvider() {
        let name = appModel.provider == .lmStudio ? "LM Studio" : "Ollama"
        let url = URL(fileURLWithPath: "/Applications/\(name).app")
        if FileManager.default.fileExists(atPath: url.path) { NSWorkspace.shared.openApplication(at: url, configuration: .init()) }
        else if let website = URL(string: appModel.provider == .lmStudio ? "https://lmstudio.ai/download" : "https://ollama.com/download") { NSWorkspace.shared.open(website) }
    }
}
