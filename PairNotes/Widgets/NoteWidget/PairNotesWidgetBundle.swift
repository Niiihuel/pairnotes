import SwiftUI
import WidgetKit

@main
struct PairNotesWidgetBundle: WidgetBundle {
    var body: some Widget {
        NoteWidget()
        ReceivedMessageWidget()
        TogetherWidget()
        AnniversaryWidget()
        DistanceWidget()
        ThinkingOfYouWidget()
    }
}
