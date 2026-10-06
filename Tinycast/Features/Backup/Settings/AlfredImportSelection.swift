import SwiftUI

/// The category picker for the Backup pane's Alfred section.
struct AlfredImportSelection: View {
    @Binding var selection: AlfredImportOptions

    private struct Category: Identifiable {
        let option: AlfredImportOptions
        let symbol: String
        let label: String
        var id: Int { option.rawValue }
    }

    private static let categories: [Category] = [
        .init(option: .shortcuts, symbol: "command", label: "Shortcuts"),
        .init(option: .searchScope, symbol: "folder", label: "Search scope"),
        .init(option: .snippets, symbol: "curlybraces", label: "Snippets"),
        .init(option: .quicklinks, symbol: Quicklink.sfSymbol, label: "Bookmarks & searches"),
        .init(option: .workflows, symbol: CustomCommand.sfSymbol, label: "Workflows")
    ]

    private static let columns = Array(
        repeating: GridItem(.flexible(), spacing: Theme.Spacing.md, alignment: .leading), count: 3)

    private func included(_ option: AlfredImportOptions) -> Binding<Bool> {
        Binding(
            get: { selection.contains(option) },
            set: { selection = $0 ? selection.union(option) : selection.subtracting(option) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            LazyVGrid(columns: Self.columns, alignment: .leading, spacing: Theme.Spacing.sm) {
                ForEach(Self.categories) { category in
                    Toggle(isOn: included(category.option)) {
                        HStack(spacing: Theme.Spacing.sm) {
                            Image(systemName: category.symbol)
                                .foregroundStyle(.secondary)
                                .frame(width: 16)
                            Text(category.label).lineLimit(1)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
            Button(selection == .all ? "Deselect All" : "Select All") {
                selection = selection == .all ? [] : .all
            }
            .buttonStyle(.link)
            .font(.caption)
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
