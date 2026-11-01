import SwiftUI

// ┌──────────────────────────────────────────────────────────────────────┐
// │ THE ONE PLACE where every package's settings go.                     │
// │                                                                      │
// │ Each pane lists its sections top to bottom. To add a package's       │
// │ section, put `<X>SettingsSection()` on its own line just above the   │
// │ pane's "▸ <Pane>: add sections above this line" marker. Each section │
// │ is a SwiftUI view with no arguments, usually a `Section { … }`; the  │
// │ pane hosts it in a grouped Form. When a pane gets its first real     │
// │ section, delete that pane's `SettingsPanePlaceholderSection` line.   │
// │ A pane with more than 10 lines: wrap some in `Group { … }`.          │
// └──────────────────────────────────────────────────────────────────────┘

enum SparkVSettingsPanes {
    @MainActor @ViewBuilder
    static func sections(for pane: SparkVSettingsPane) -> some View {
        switch pane {
        case .general:
            AppShellAboutSettingsSection()
            AppShellStartupSettingsSection()
            AppShellMenuBarSettingsSection()
            AppShellUpdatesSettingsSection()
            OnboardingSettingsSection()
            SettingsCardRow { LocalizationSettingsSection() }
            // ▸ General: add sections above this line

        case .island:
            Group {
                AppShellIslandLinksSettingsSection()
                LayoutSettingsSection()
                LayoutFeaturesSettingsSection()
            }
            Group {
                IslandDisplaySettingsSection()
                IslandVisibilitySettingsSection()
                IslandExcludedAppsSettingsSection()
                IslandOpeningSettingsSection()
                IslandMenuBarSettingsSection()
            }
            Group {
                SettingsCardRow { QuickTogglesSettingsSection() }
                SettingsCardRow { ClosedIslandMediaSettingsSection() }
                SettingsCardRow { IdleHomeSettingsSection() }
            }
            // ▸ Island: add sections above this line

        case .media:
            Group {
                SettingsCardRow { MediaControlsSettingsSection() }
                SettingsCardRow { MediaSourcesSettingsSection() }
                SettingsCardRow { MediaGesturesSettingsSection() }
                SettingsCardRow { LyricsSettingsSection() }
                SettingsCardRow { SpotifyLikesSettingsSection() }
            }
            Group {
                SettingsCardRow { MicMuteSettingsSection() }
                SettingsCardRow { CameraMirrorSettingsSection() }
            }
            // ▸ Media: add sections above this line

        case .system:
            Group {
                AppShellPermissionsSettingsSection()
                HUDSettingsSection()
                HUDDisplaysSettingsSection()
            }
            Group {
                SettingsCardRow { SoundOutputSettingsSection() }
                SettingsCardRow { AppVolumeSettingsSection() }
            }
            Group {
                SettingsCardRow { BatterySettingsSection() }
                SettingsCardRow { PeripheralBatterySettingsSection() }
                SettingsCardRow { KeepAwakeSettingsSection() }
                SettingsCardRow { MenuBarOverflowSettingsSection() }
            }
            EnergySettingsSection()
            // ▸ System: add sections above this line

        case .activities:
            Group {
                LiveActivitiesSettingsSection()
                NotificationsSettingsSection()
                CallsSettingsSection()
                ActivityTimingSettingsSection()
            }
            Group {
                SettingsCardRow { PrivacyIndicatorSettingsSection() }
                SettingsCardRow { ConnectivitySettingsSection() }
            }
            // ▸ Activities: add sections above this line

        case .planner:
            Section { CalendarSettingsSection() }
            Section { RemindersSettingsSection() }
            Section { TimerSettingsSection() }
            Section { WeatherSettingsSection() }
            Section { LauncherSettingsSection() }
            // ▸ Planner: add sections above this line

        case .shelf:
            ShelfSettingsSection()
            ShelfDragSettingsSection()
            FileDropSettingsSection()
            NearbyShareSettingsSection()
            FileTransfersSettingsSection()
            DownloadsSettingsSection()
            // ▸ Shelf: add sections above this line

        case .extras:
            SettingsCardRow { CodingAgentsSettingsSection() }
            SettingsCardRow { DevStatusSettingsSection() }
            SettingsCardRow { ScriptWidgetSettingsSection() }
            SettingsCardRow { TeleprompterSettingsSection() }
            AppShellExtrasLinksSettingsSection()
            // ▸ Extras: add sections above this line

        case .appearance:
            Group {
                AppearanceSettingsSection()
                NotchThemeSettingsSection()
            }
            Group {
                IslandStyleSettingsSection()
                IslandBlackMenuBarSettingsSection()
                IslandMotionSettingsSection()
                IslandSizeSettingsSection()
                HUDStyleSettingsSection()
            }
            // ▸ Appearance: add sections above this line

        case .accessibility:
            TextContrastSettingsSection()
            AppShellAccessibilityStatusSection()
            IslandHapticsSettingsSection()
            VoiceOverAnnouncementsSettingsSection()
            DrawerShortcutsSettingsSection()
            SettingsCardRow { CapsLockSettingsSection() }
            // ▸ Accessibility: add sections above this line

        case .advanced:
            Group {
                AppShellAutomationSettingsSection()
                AppShellDiagnosticsSettingsSection()
                AppShellResetSettingsSection()
            }
            Group {
                IslandCapturePrivacySettingsSection()
                IslandRecoverySettingsSection()
                IslandCoexistenceSettingsSection()
            }
            // ▸ Advanced: add sections above this line
        }
    }
}
