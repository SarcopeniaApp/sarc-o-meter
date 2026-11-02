//  sarc_o_meterWidgetLiveActivity.swift
//  sarc-o-meterWidget
//

import ActivityKit
import WidgetKit
import SwiftUI

struct ModelDownloadLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ModelDownloadActivityAttributes.self) { context in
            // MARK: - Lock Screen / Notification Center Banner
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(Color.cyan.opacity(0.15))
                        .frame(width: 44, height: 44)
                    Image(systemName: "sparkles")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.cyan)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(context.attributes.modelName)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.primary)
                        Spacer()
                        Text("\(context.state.percent)%")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(.cyan)
                    }

                    ProgressView(value: context.state.progress)
                        .tint(.cyan)

                    Text(context.state.progressText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .background(Color(.systemBackground))
        } dynamicIsland: { context in
            DynamicIsland {
                // MARK: - Expanded Dynamic Island (saat ditekan lama)
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .foregroundStyle(.cyan)
                        Text(context.attributes.modelName)
                            .font(.system(size: 14, weight: .bold))
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(context.state.percent)%")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(.cyan)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 8) {
                        ProgressView(value: context.state.progress)
                            .tint(.cyan)
                        Text(context.state.progressText)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                }
            } compactLeading: {
                // MARK: - Compact Left (di samping kiri kamera)
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.cyan)
            } compactTrailing: {
                // MARK: - Compact Right (Animasi melingkar di samping kanan kamera)
                HStack(spacing: 4) {
                    ProgressView(value: context.state.progress)
                        .progressViewStyle(.circular)
                        .tint(.cyan)
                        .scaleEffect(0.8)
                    Text("\(context.state.percent)%")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.cyan)
                }
            } minimal: {
                // MARK: - Minimal Mode (Animasi lingkaran kecil di sekitar kamera)
                ProgressView(value: context.state.progress)
                    .progressViewStyle(.circular)
                    .tint(.cyan)
                    .scaleEffect(0.8)
            }
        }
    }
}

