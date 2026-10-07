import SwiftUI

/// SwiftUI's `State` property wrapper under another name.
///
/// In the current SDK `@State` resolves to a macro whose compiler plugin
/// (SwiftUIMacros) ships only with Xcode, so it fails to build with just the
/// Command Line Tools. The wrapper type itself is unchanged; this alias reaches
/// it without the macro. Use `@ViewState` wherever you'd write `@State`.
typealias ViewState<Value> = SwiftUI.State<Value>
