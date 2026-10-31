/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// DisplayAccessApp.swift
//
// Main entry point for the DisplayAccess app demonstrating the Meta Wearables DAT SDK
// Display module. This app shows how to send visual content to wearable display devices.
//

import MWDATCore
import SwiftUI

private enum AppTab: Hashable {
  case library
  case samples
  case settings
}

@main
struct DisplayAccessApp: App {
  @State private var wearablesViewModel: WearablesViewModel
  @State private var displayViewModel: DisplayViewModel
  @State private var library = HarnessLibrary()
  @State private var reader = HarnessReader()
  @Environment(\.scenePhase) private var scenePhase
  @State private var selectedTab: AppTab = .library

  init() {
    do {
      try Wearables.configure()
    } catch {
      #if DEBUG
      NSLog("[DisplayAccess] Failed to configure Wearables SDK: \(error)")
      #endif
    }

    let wearables = Wearables.shared
    self._wearablesViewModel = State(wrappedValue: WearablesViewModel(wearables: wearables))
    self._displayViewModel = State(wrappedValue: DisplayViewModel(wearables: wearables))
  }

  var body: some Scene {
    WindowGroup {
      TabView(selection: $selectedTab) {
        NavigationStack {
          HarnessLibraryView(
            display: displayViewModel, library: library, reader: reader,
            glassesAvailable: wearablesViewModel.deviceItemStates.contains { !$0.isPhonePreview && $0.linkState == .connected },
            openSettings: { selectedTab = .settings }
          )
        }
        .tabItem { Label("Library", systemImage: "doc.text") }
        .tag(AppTab.library)

        NavigationStack {
          SampleAppsView(
            displayViewModel: displayViewModel,
            developerPreviewMode: wearablesViewModel.developerPreviewMode,
            isDeveloperPreviewChanging: wearablesViewModel.isDeveloperPreviewChanging,
            phonePreviewDisplay: wearablesViewModel.phonePreviewDisplay,
            phonePreviewDeviceIdentifier: wearablesViewModel.phonePreviewDeviceIdentifier,
            chromePreviewURL: wearablesViewModel.chromePreviewURL,
            developerPreviewErrorMessage: wearablesViewModel.developerPreviewErrorMessage,
            setDeveloperPreviewMode: setDeveloperPreviewMode
          )
        }
        .harnessSheetStyle()
        .tabItem {
          Label("Samples", systemImage: "eyeglasses")
        }
        .tag(AppTab.samples)

        NavigationStack {
          SettingsView(
            viewModel: SettingsViewModel(
              registrationState: wearablesViewModel.registrationState,
              deviceItemStates: wearablesViewModel.deviceItemStates,
              requiresFirmwareUpdate: wearablesViewModel.requiresFirmwareUpdate,
              requiresDATAppUpdate: displayViewModel.requiresDATAppUpdate,
              connectGlasses: {
                Task {
                  await wearablesViewModel.connectGlasses()
                }
              },
              disconnectGlasses: {
                Task {
                  await wearablesViewModel.disconnectGlasses()
                }
              },
              openFirmwareUpdate: {
                wearablesViewModel.openFirmwareUpdate()
              },
              openDATGlassesAppUpdate: {
                wearablesViewModel.openDATGlassesAppUpdate()
              }
            )
          )
        }
        .harnessSheetStyle()
        .tabItem {
          Label("Settings", systemImage: "gearshape")
        }
        .tag(AppTab.settings)
      }
      .tint(HarnessTheme.mint)
      .preferredColorScheme(.dark)
      .toolbarBackground(HarnessTheme.background, for: .tabBar)
      .toolbarBackground(.visible, for: .tabBar)
      .task { await library.drive.restore() }
      .task(id: libraryConnectionKey) {
        // A new connected device/foreground activation can recreate a stopped
        // session. Do not retry continuously after errors or an explicit stop.
        guard scenePhase == .active, selectedTab == .library,
              wearablesViewModel.registrationState == .registered,
              wearablesViewModel.deviceItemStates.contains(where: { !$0.isPhonePreview && $0.linkState == .connected }),
              (!displayViewModel.isConnected || displayViewModel.onHarnessInput == nil),
              !displayViewModel.isSending else { return }
        await reader.presentLibrary(library, display: displayViewModel)
      }
      .alert("Error", isPresented: $wearablesViewModel.showError) {
        Button("OK") { wearablesViewModel.dismissError() }
      } message: {
        Text(wearablesViewModel.errorMessage)
      }

      RegistrationView(viewModel: wearablesViewModel)
    }
  }

  private var libraryConnectionKey: String {
    let devices = wearablesViewModel.deviceItemStates
      .filter { !$0.isPhonePreview && $0.linkState == .connected }
      .map { String(describing: $0.identifier) }.sorted().joined(separator: ",")
    return "\(scenePhase)-\(selectedTab)-\(wearablesViewModel.registrationState)-\(devices)-\(library.availableLocations.count)-\(library.drive.accountID ?? "")-\(library.drive.busy)"
  }

  private func setDeveloperPreviewMode(_ mode: DeveloperPreviewMode?) async -> Bool {
    await wearablesViewModel.setDeveloperPreviewMode(
      mode,
      stopDisplaySession: displayViewModel.stopSession
    )
  }
}
