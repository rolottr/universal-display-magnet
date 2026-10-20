import SwiftUI

/// Local view state without `@State`: on the macOS 27 SDK `@State` is a macro
/// whose plugin ships only with full Xcode, and this project builds with the
/// Command Line Tools alone. `@StateObject` is a plain property wrapper.
final class ViewState<Value>: ObservableObject {
    @Published var value: Value

    init(_ value: Value) {
        self.value = value
    }
}
