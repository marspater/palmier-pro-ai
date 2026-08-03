import AppKit
import SwiftUI

struct ToolbarView: View {
    @Environment(EditorViewModel.self) var editor

    var body: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            // Undo / Redo
            HStack(spacing: AppTheme.Spacing.xs) {
                toolbarButton("arrow.uturn.backward", help: "Undo (⌘Z)", action: undo)
                toolbarButton("arrow.uturn.forward", help: "Redo (⇧⌘Z)", action: redo)
            }

            Divider().frame(height: AppTheme.Spacing.xl)

            // Editing Tool Modes
            HStack(spacing: AppTheme.Spacing.xs) {
                toolModeButton("cursorarrow", mode: .pointer, help: "Pointer (V)")
                toolModeButton("scissors", mode: .razor, help: "Razor (C)")
                toolModeButton("arrow.left.and.right", mode: .trim, help: "Trim (T)")
            }

            Divider().frame(height: AppTheme.Spacing.xl)

            // Cutting & Trimming Actions
            HStack(spacing: AppTheme.Spacing.xs) {
                toolbarButton("square.split.2x1", help: "Split at Playhead (⌘K)", action: editor.splitAtPlayhead)
                bracketButton("[", help: "Trim Start to Playhead (Q)", action: editor.trimStartToPlayhead)
                bracketButton("]", help: "Trim End to Playhead (W)", action: editor.trimEndToPlayhead)
            }

            Divider().frame(height: AppTheme.Spacing.xl)

            // Add Generators & Elements
            HStack(spacing: AppTheme.Spacing.xs) {
                textGlyphButton("T", help: "Add Text Clip", action: { _ = editor.addTextClip() })
                toolbarButton("square.fill", help: "Add Solid Color / Shape", action: { _ = editor.addSolidColorClip() })
                toolbarButton("bookmark.fill", help: "Add Marker (M)", action: editor.addMarkerAtPlayhead)
            }

            Divider().frame(height: AppTheme.Spacing.xl)

            // Aspect Ratio & Resolution Quick Selector
            aspectRatioMenu

            // FPS Quick Selector
            fpsMenu

            Spacer()

            // Panel Toggles
            HStack(spacing: AppTheme.Spacing.xs) {
                panelToggleButton("sidebar.left", label: "Media", isVisible: editor.mediaPanelVisible) {
                    editor.mediaPanelVisible.toggle()
                }
                panelToggleButton("sidebar.right", label: "Inspector", isVisible: editor.inspectorPanelVisible) {
                    editor.inspectorPanelVisible.toggle()
                }
                panelToggleButton("slider.horizontal.below.square.filled.and.square", label: "Keyframes", isVisible: editor.keyframesPanelVisible) {
                    editor.keyframesPanelVisible.toggle()
                }
                panelToggleButton("sparkles", label: "AI Chat", isVisible: editor.agentPanelVisible) {
                    editor.agentPanelVisible.toggle()
                }
            }

            Divider().frame(height: AppTheme.Spacing.xl)

            // Zoom Controls
            HStack(spacing: AppTheme.Spacing.xxs) {
                zoomButton(
                    "minus.magnifyingglass",
                    help: "Zoom Out",
                    isDisabled: editor.zoomScale <= editor.minZoomScale,
                    action: zoomOut
                )
                let zoomBinding = Binding(
                    get: { log(editor.zoomScale) },
                    set: { editor.zoomScale = exp($0) }
                )
                Slider(value: zoomBinding, in: log(editor.minZoomScale)...log(Zoom.max))
                    .controlSize(.mini)
                    .tint(AppTheme.Accent.primary)
                    .frame(width: 80)
                zoomButton(
                    "plus.magnifyingglass",
                    help: "Zoom In",
                    isDisabled: editor.zoomScale >= Zoom.max,
                    action: zoomIn
                )
            }

            Divider().frame(height: AppTheme.Spacing.xl)

            // Quick Export Button
            Button {
                editor.showExportDialog = true
            } label: {
                HStack(spacing: AppTheme.Spacing.xs) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: AppTheme.FontSize.xs, weight: .semibold))
                    Text("Export")
                        .font(.system(size: AppTheme.FontSize.xs, weight: .semibold))
                }
                .padding(.horizontal, AppTheme.Spacing.sm)
                .padding(.vertical, AppTheme.Spacing.xxs)
                .background(AppTheme.Accent.primary)
                .foregroundStyle(Color.black)
                .cornerRadius(AppTheme.Radius.sm)
            }
            .buttonStyle(.plain)
            .help("Export Video (⇧⌘E)")
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Subviews & Controls

    private var aspectRatioMenu: some View {
        Menu {
            Button("16:9 Landscape (1920x1080)") {
                editor.setTimelineResolution(width: 1920, height: 1080)
            }
            Button("9:16 Vertical (1080x1920)") {
                editor.setTimelineResolution(width: 1080, height: 1920)
            }
            Button("1:1 Square (1080x1080)") {
                editor.setTimelineResolution(width: 1080, height: 1080)
            }
            Button("4:3 Standard (1440x1080)") {
                editor.setTimelineResolution(width: 1440, height: 1080)
            }
            Button("21:9 UltraWide (2560x1080)") {
                editor.setTimelineResolution(width: 2560, height: 1080)
            }
            Button("4K UHD (3840x2160)") {
                editor.setTimelineResolution(width: 3840, height: 2160)
            }
        } label: {
            HStack(spacing: AppTheme.Spacing.xxs) {
                Image(systemName: "aspectratio")
                    .font(.system(size: AppTheme.FontSize.xs))
                Text("\(editor.timeline.width)x\(editor.timeline.height)")
                    .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
            }
            .foregroundStyle(AppTheme.Text.secondaryColor)
            .padding(.horizontal, AppTheme.Spacing.xs)
            .padding(.vertical, AppTheme.Spacing.xxs)
            .background(RoundedRectangle(cornerRadius: AppTheme.Radius.sm).fill(AppTheme.Background.raisedColor))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .help("Canvas Aspect Ratio & Resolution")
    }

    private var fpsMenu: some View {
        Menu {
            Button("24 fps (Film)") { editor.timeline.fps = 24 }
            Button("25 fps (PAL)") { editor.timeline.fps = 25 }
            Button("30 fps (Standard)") { editor.timeline.fps = 30 }
            Button("60 fps (High Smoothness)") { editor.timeline.fps = 60 }
        } label: {
            HStack(spacing: AppTheme.Spacing.xxs) {
                Image(systemName: "timer")
                    .font(.system(size: AppTheme.FontSize.xs))
                Text("\(editor.timeline.fps)fps")
                    .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
            }
            .foregroundStyle(AppTheme.Text.secondaryColor)
            .padding(.horizontal, AppTheme.Spacing.xs)
            .padding(.vertical, AppTheme.Spacing.xxs)
            .background(RoundedRectangle(cornerRadius: AppTheme.Radius.sm).fill(AppTheme.Background.raisedColor))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .help("Timeline Frame Rate (FPS)")
    }

    private func panelToggleButton(_ systemName: String, label: String, isVisible: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(isVisible ? AppTheme.Accent.primary : AppTheme.Text.tertiaryColor)
                .frame(width: 24, height: 24)
                .hoverHighlight(isActive: isVisible)
        }
        .buttonStyle(.plain)
        .help("Toggle \(label)")
    }

    private func toolbarButton(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: AppTheme.FontSize.md))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .frame(width: 24, height: 24)
                .hoverHighlight()
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func zoomButton(
        _ systemName: String,
        help: String,
        isDisabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(isDisabled ? AppTheme.Text.mutedColor : AppTheme.Text.tertiaryColor)
                .frame(width: AppTheme.IconSize.mdLg, height: AppTheme.IconSize.mdLg)
                .hoverHighlight()
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(help)
    }

    private func zoomOut() {
        setZoomScale(editor.zoomScale / Zoom.toolbarStepFactor)
    }

    private func zoomIn() {
        setZoomScale(editor.zoomScale * Zoom.toolbarStepFactor)
    }

    private func setZoomScale(_ zoomScale: Double) {
        editor.zoomScale = min(Zoom.max, max(editor.minZoomScale, zoomScale))
    }

    private func undo() {
        NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
    }

    private func redo() {
        NSApp.sendAction(Selector(("redo:")), to: nil, from: nil)
    }

    private func toolModeButton(_ systemName: String, mode: ToolMode, help: String) -> some View {
        let isActive = editor.toolMode == mode
        return Button { editor.toolMode = mode } label: {
            Image(systemName: systemName)
                .font(.system(size: AppTheme.FontSize.md))
                .foregroundStyle(isActive ? AppTheme.Text.primaryColor : AppTheme.Text.tertiaryColor)
                .frame(width: 24, height: 24)
                .hoverHighlight(isActive: isActive)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func textGlyphButton(_ glyph: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(glyph)
                .font(.system(size: 17, weight: .bold, design: .serif))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .frame(width: 24, height: 24)
                .hoverHighlight()
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func bracketButton(_ bracket: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(bracket)
                .font(.system(size: 16, weight: .semibold, design: .monospaced))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .frame(width: 24, height: 24)
                .hoverHighlight()
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
