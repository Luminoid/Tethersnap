import SwiftUI

/// Bottom inset of the detail pane: the progress chips of the runs in flight
/// (an export and a date fix may run side by side), each run's summary chip
/// with its own dismiss, else the status line.
struct StatusBar: View {
    @Environment(AppModel.self) private var model

    private var showsRuns: Bool {
        model.exportProgress != nil || model.dateFixProgress != nil || model.exportSummary != nil || model.dateFixSummary != nil
    }

    var body: some View {
        if showsRuns {
            VStack(spacing: Layout.spacingSmall) {
                if let progress = model.exportProgress {
                    ProgressChip(fraction: progress.overallFraction,
                                 label: L10n.exportProgress(min(progress.completed + 1, progress.total), progress.total),
                                 cancelHelp: L10n.helpCancelExport,
                                 onCancel: { model.cancelExport() })
                }
                if let progress = model.dateFixProgress {
                    ProgressChip(fraction: progress.total > 0 ? progress.fraction : nil,
                                 label: progress.total > 0
                                     ? L10n.dateFixProgress(min(progress.completed + 1, progress.total), progress.total)
                                     : L10n.dateFixPreparing,
                                 cancelHelp: L10n.helpCancelFixDates,
                                 onCancel: { model.cancelDateFix() })
                }
                if let summary = model.exportSummary {
                    SummaryChip(summary: summary, onDismiss: { model.dismissExportSummary() })
                }
                if let summary = model.dateFixSummary {
                    SummaryChip(summary: summary, onDismiss: { model.dismissDateFixSummary() })
                }
            }
            .padding([.horizontal, .bottom], Layout.spacingLarge)
        } else {
            HStack(spacing: Layout.spacingMedium) {
                if let failure = model.logFileFailure {
                    // Non-blocking: the app works without the file; the tooltip says why.
                    Label(L10n.logFileUnavailable, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .help(failure)
                }
                Spacer()
                StatusChip()
            }
            .padding(.horizontal, Layout.spacingLarge)
            .padding(.bottom, Layout.spacingSmall)
        }
    }
}

/// Export and date-fix progress: a bar (indeterminate while `fraction` is
/// nil), one line, and Cancel (its tooltip names the shortcut).
private struct ProgressChip: View {
    let fraction: Double?
    let label: String
    let cancelHelp: String
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: Layout.spacingMedium) {
            if let fraction {
                ProgressView(value: fraction)
                    .frame(maxWidth: Layout.progressBarWidth)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
            Text(label)
                .font(.callout)
                .monospacedDigit()
            Button(L10n.cancel) { onCancel() }
                .controlSize(.small)
                .help(cancelHelp)
        }
        .padding(Layout.spacingMedium)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Layout.cornerRadius))
    }
}

private struct SummaryChip: View {
    @Environment(AppModel.self) private var model
    let summary: AppModel.ExportSummary
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: Layout.spacingMedium) {
            Text(summary.message)
                .font(.callout)
                .help(summary.detail ?? summary.message)
            if let folder = summary.folder {
                Button(L10n.showInFinder) { model.revealInFinder(folder) }
                    .controlSize(.small)
            }
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel(L10n.close)
        }
        .padding(Layout.spacingMedium)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Layout.cornerRadius))
    }
}

/// Colored dot + one line reflecting the state machine, so the app always
/// says what it currently sees (e.g. "No source selected").
private struct StatusChip: View {
    @Environment(AppModel.self) private var model

    private var color: Color {
        switch model.phase {
        case .noSource: Layout.statusIdleColor
        case .opening: Layout.statusBusyColor
        case .ready: Layout.statusReadyColor
        case .failed: Layout.statusFailedColor
        }
    }

    var body: some View {
        HStack(spacing: Layout.spacingSmall) {
            Circle()
                .fill(color)
                .frame(width: Layout.statusDotSize, height: Layout.statusDotSize)
            Text(model.statusLabel)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
