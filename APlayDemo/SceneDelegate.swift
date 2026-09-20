//
//  SceneDelegate.swift
//  APlayDemo
//
//  Hosts the SwiftUI interface. The demo ships no Main storyboard — background
//  audio and remote commands need the audio background mode, and the UI is
//  fully SwiftUI from launch.
//

import SwiftUI
import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(_ scene: UIScene,
               willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = UIHostingController(rootView: ContentView())
        window.overrideUserInterfaceStyle = .dark
        window.makeKeyAndVisible()
        self.window = window
    }
}
