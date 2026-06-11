import WidgetKit
import SwiftUI

@main
struct PodcatcherWidgetBundle: WidgetBundle {
    var body: some Widget {
        NowPlayingWidget()
        ContinueListeningWidget()
        #if os(iOS) && !targetEnvironment(macCatalyst)
        NowPlayingLiveActivity()
        #endif
    }
}
