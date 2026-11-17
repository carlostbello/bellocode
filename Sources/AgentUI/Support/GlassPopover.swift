import DesignSystem
import SwiftUI

/// AgentUI's pickers on DesignSystem's `glassPopover`, carrying the host's `AgentUIStyle` into the panel.
extension View {
    func agentGlassPopover<Content: View>(
        isPresented: Binding<Bool>, width: CGFloat, @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        modifier(AgentGlassPopover(isPresented: isPresented, width: width, popoverContent: content))
    }
}

private struct AgentGlassPopover<PopoverContent: View>: ViewModifier {
    @Binding var isPresented: Bool
    let width: CGFloat
    let popoverContent: () -> PopoverContent
    @Environment(\.agentUIStyle) private var style

    func body(content: Content) -> some View {
        let style = style
        return content.glassPopover(
            isPresented: $isPresented, width: width, transformContent: { AnyView($0.environment(\.agentUIStyle, style)) },
            content: popoverContent)
    }
}
