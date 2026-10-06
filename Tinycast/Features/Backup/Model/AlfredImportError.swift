import Foundation

enum AlfredImportError: LocalizedError {
    case notAlfredPackage

    var errorDescription: String? {
        switch self {
        case .notAlfredPackage:
            return "This doesn't look like an Alfred preferences package (Alfred.alfredpreferences)."
        }
    }
}
