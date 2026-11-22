import PortalHostModel
import SwiftUI

/// The folders games are looked up in: the application folders (fixed) and the ones the person added.
struct FoldersView: View {
    let controller: HostController
    private var model: HostModel { controller.model }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Strings.foldersFixed).font(.subheadline.weight(.semibold))
            ForEach(HostModel.standardRoots, id: \.self) { folder in
                Text(folder.pathAbbreviated).foregroundStyle(.secondary)
            }
            Divider()
            Text(Strings.foldersAdded).font(.subheadline.weight(.semibold))
            if model.settings.folders.isEmpty { Text(Strings.noAddedFolders).foregroundStyle(.secondary) }
            ForEach(model.settings.folders, id: \.self) { folder in
                HStack {
                    Text(folder.pathAbbreviated).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button(Strings.remove) { controller.removeFolder(folder) }
                }
            }
            if let message = controller.shownMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Spacer()
                Button(Strings.add) { controller.chooseFolder() }
            }
        }
        .padding(16)
        .frame(width: 420)
    }
}

private extension URL {
    /// `~/Applications` for a folder in the home folder.
    var pathAbbreviated: String { (path as NSString).abbreviatingWithTildeInPath }
}
